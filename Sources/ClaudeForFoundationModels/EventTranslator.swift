// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

/// Marks a reasoning entry as a redacted thought — replayed as
/// `redacted_thinking` rather than a `thinking` block.
let redactedThinkingMetadataKey = "claude.redactedThinking"

/// Translates the Messages API SSE stream into channel events.
///
/// One translation produces at most one response entry and one tool-calls
/// entry; their IDs are fixed at init so every event for a turn targets the
/// same entries.
struct EventTranslator: Sendable {
  let responseEntryID: String
  let toolCallsEntryID: String

  init(
    responseEntryID: String = UUID().uuidString,
    toolCallsEntryID: String = UUID().uuidString
  ) {
    self.responseEntryID = responseEntryID
    self.toolCallsEntryID = toolCallsEntryID
  }

  /// Per-block state across the stream — `content_block_delta` only carries
  /// an index, not the kind, so we have to remember `content_block_start`.
  /// Server tool inputs accumulate locally (they stream as `input_json_delta`)
  /// and emit a custom segment at `content_block_stop`.
  private enum BlockKind: Sendable {
    case text
    /// One reasoning entry per thinking block. A fresh id per block keeps each
    /// block's signature distinct — `updateSignature` replaces wholesale, so
    /// sharing one entry across blocks would clobber earlier signatures.
    case thinking(entryID: String)
    case toolUse(id: String, name: String)
    /// `initialInput` is the start block's `input` — some server tools (the
    /// agentic search flow) deliver the whole input there with no deltas.
    case serverToolUse(id: String, name: String, initialInput: JSONValue, accumulatedInput: String)
  }

  func translate(
    _ events: AsyncThrowingStream<StreamEvent, Error>,
    into channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    var blocks: [Int: BlockKind] = [:]
    /// In-flight server-tool calls by tool-use id, so a result updates the
    /// same segment its call created.
    var pendingServerTools: [String: ClaudeServerToolSegment.Content] = [:]
    var promptTokens = 0
    var cachedTokens = 0

    for try await event in events {
      try Task.checkCancellation()

      switch event {
      case .messageStart(let response):
        // `input_tokens` counts only the uncached prompt; cache reads and
        // writes arrive in separate fields. The framework's total is the
        // whole prompt, with cache reads as the cached subset.
        cachedTokens = response.usage.cacheReadInputTokens ?? 0
        promptTokens =
          (response.usage.inputTokens ?? 0)
          + cachedTokens
          + (response.usage.cacheCreationInputTokens ?? 0)

      case .contentBlockStart(let index, let block):
        let blockKind = kind(of: block)
        blocks[index] = blockKind
        switch block {
        case .redactedThinking(let data):
          // Redacted thoughts arrive whole as opaque bytes. Surface them as a
          // signature-only reasoning entry (no text) so the request builder
          // can replay them — the API requires redacted blocks back verbatim
          // to keep the thought chain verifiable.
          if case .thinking(let reasoningEntryID) = blockKind {
            await channel.send(
              .reasoning(
                entryID: reasoningEntryID,
                action: .updateMetadata([redactedThinkingMetadataKey: true])
              )
            )
            await channel.send(
              .reasoning(
                entryID: reasoningEntryID,
                action: .updateSignature(data, tokenCount: 0)
              )
            )
          }
        case .toolUse(let id, let name, _):
          await channel.send(
            .toolCalls(
              entryID: toolCallsEntryID,
              action: .toolCall(id: id, name: name, action: .appendArguments("", tokenCount: 0))
            )
          )
        case .serverToolUse(let id, let name, let input) where input != .object([:]):
          // When the call's input arrives whole in the start block, surface
          // the segment immediately; the stop handler re-emits the same id.
          // An empty input means the real input is still streaming as deltas,
          // and parsing it now would mislabel a known tool as unrecognized.
          await channel.send(
            .response(
              entryID: responseEntryID,
              action: .updateCustomSegment(
                ClaudeServerToolSegment(
                  id: id,
                  content: .init(callToolName: name, input: input)
                )
              )
            )
          )
        case .serverToolResult(let toolUseID, let type, let content):
          // Results arrive whole in the start event, not as deltas. Updating
          // the call's segment id folds call and result into one segment.
          let merged =
            pendingServerTools.removeValue(forKey: toolUseID)?
            .merging(resultType: type, payload: content)
            ?? .unrecognized(
              .init(
                toolName: toolName(fromResultType: type),
                resultType: type,
                resultJSON: content.jsonText
              )
            )
          await channel.send(
            .response(
              entryID: responseEntryID,
              action: .updateCustomSegment(
                ClaudeServerToolSegment(id: toolUseID, content: merged)
              )
            )
          )
        default:
          break
        }

      case .contentBlockDelta(let index, let delta):
        if case .serverToolUse(let id, let name, let initial, var acc) = blocks[index],
          case .inputJSON(let chunk) = delta
        {
          acc += chunk
          blocks[index] = .serverToolUse(
            id: id,
            name: name,
            initialInput: initial,
            accumulatedInput: acc
          )
        } else {
          try await send(delta, for: blocks[index], to: channel)
        }

      case .contentBlockStop(let index):
        if case .serverToolUse(let id, let name, let initial, let accumulated) = blocks[index] {
          // Deltas win when they streamed; otherwise the input arrived whole
          // in the start block.
          let payload =
            accumulated.isEmpty
            ? initial
            : JSONValue.parsed(accumulated) ?? .null
          let content = ClaudeServerToolSegment.Content(callToolName: name, input: payload)
          pendingServerTools[id] = content
          await channel.send(
            .response(
              entryID: responseEntryID,
              action: .updateCustomSegment(
                ClaudeServerToolSegment(id: id, content: content)
              )
            )
          )
        }
        blocks.removeValue(forKey: index)

      case .messageDelta(_, let usage):
        // Server-tool turns grow the prompt mid-turn; message_delta carries
        // updated input-side totals when that happens.
        if usage.inputTokens != nil || usage.cacheReadInputTokens != nil {
          cachedTokens = usage.cacheReadInputTokens ?? 0
          promptTokens =
            (usage.inputTokens ?? 0)
            + cachedTokens
            + (usage.cacheCreationInputTokens ?? 0)
        }
        await channel.send(
          .response(
            entryID: responseEntryID,
            action: .updateUsage(
              input: .init(totalTokenCount: promptTokens, cachedTokenCount: cachedTokens),
              output: .init(totalTokenCount: usage.outputTokens, reasoningTokenCount: 0)
            )
          )
        )

      case .messageStop, .ping, .unknown:
        break

      case .error(let apiError):
        throw apiError
      }
    }
  }

  // MARK: - Private

  private func kind(of block: ContentBlock) -> BlockKind {
    switch block {
    case .text: .text
    case .thinking, .redactedThinking: .thinking(entryID: UUID().uuidString)
    case .toolUse(let id, let name, _): .toolUse(id: id, name: name)
    case .serverToolUse(let id, let name, let input):
      .serverToolUse(id: id, name: name, initialInput: input, accumulatedInput: "")
    case .image, .toolResult, .serverToolResult, .unknown: .text
    }
  }

  /// Placeholder token count for streamed content deltas. The API reports
  /// usage only at message boundaries, so no real per-delta count exists, and
  /// a count of 0 suppresses partial-snapshot delivery. Authoritative totals
  /// still arrive via `updateUsage` at `message_delta`.
  private static let deltaTokenCount = 1

  private func send(
    _ delta: StreamEvent.Delta,
    for kind: BlockKind?,
    to channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    switch (delta, kind) {
    case (.text(let t), _):
      await channel.send(
        .response(
          entryID: responseEntryID,
          action: .appendText(t, tokenCount: Self.deltaTokenCount)
        )
      )

    case (.thinking(let t), .thinking(let reasoningEntryID)):
      await channel.send(
        .reasoning(
          entryID: reasoningEntryID,
          action: .appendText(t, tokenCount: Self.deltaTokenCount)
        )
      )

    case (.signature(let sig), .thinking(let reasoningEntryID)):
      // Opaque framing for thought verification. Pass through as bytes.
      await channel.send(
        .reasoning(
          entryID: reasoningEntryID,
          action: .updateSignature(
            Data(base64Encoded: sig) ?? Data(sig.utf8),
            tokenCount: 0
          )
        )
      )

    case (.inputJSON(let chunk), .toolUse(let id, let name)):
      await channel.send(
        .toolCalls(
          entryID: toolCallsEntryID,
          action: .toolCall(
            id: id,
            name: name,
            action: .appendArguments(chunk, tokenCount: Self.deltaTokenCount)
          )
        )
      )

    case (.thinking, _), (.signature, _), (.inputJSON, _), (.unknown, _):
      break
    }
  }

  /// `web_search_tool_result` → `web_search`. Falls back to the full type for
  /// result blocks that don't follow the suffix convention.
  private func toolName(fromResultType type: String) -> String {
    let suffix = "_tool_result"
    return type.hasSuffix(suffix) ? String(type.dropLast(suffix.count)) : type
  }
}
