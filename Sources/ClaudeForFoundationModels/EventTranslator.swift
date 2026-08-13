// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

/// Translates the Messages API SSE stream for one turn into channel events,
/// recording each completed block on the entry that presents it (see
/// ``TurnRecord``).
///
/// A turn produces at most one response entry and one tool-calls entry;
/// their IDs are fixed at init so every event for the turn targets the same
/// entries. A turn can span several responses when the API pauses it
/// (`pause_turn`): feed each response's stream to the same translator, and
/// ``content`` accumulates across them.
struct EventTranslator: Sendable {
  let responseEntryID: String
  let toolCallsEntryID: String

  /// The turn's content blocks completed so far, as the API sent them.
  private(set) var content: [JSONValue] = []

  private var assembler = ContentAssembler()
  private let turn = UUID().uuidString
  /// The stored form of what the response entry has recorded so far;
  /// metadata updates replace wholesale, so all of it is sent each time it
  /// grows.
  private var responseStored: [String] = []
  /// Prompt-side and output totals of the responses already finished, so a
  /// continued turn reports the whole turn's usage.
  private var settledUsage = TurnUsage()
  private var currentUsage = TurnUsage()

  fileprivate struct TurnUsage {
    var prompt = 0
    var cached = 0
    var output = 0

    static func + (a: Self, b: Self) -> Self {
      Self(prompt: a.prompt + b.prompt, cached: a.cached + b.cached, output: a.output + b.output)
    }
  }

  init(
    responseEntryID: String = UUID().uuidString,
    toolCallsEntryID: String = UUID().uuidString
  ) {
    self.responseEntryID = responseEntryID
    self.toolCallsEntryID = toolCallsEntryID
  }

  /// ``content`` as the final assistant message of a continuation request:
  /// as sent, less any trailing whitespace text, which the API refuses at
  /// the end of a final assistant message.
  var continuationContent: [ContentBlock] {
    var blocks = content
    while let last = blocks.last, case .text(let text) = TurnRecord.Kind(last),
      case .object(var fields) = last
    {
      blocks.removeLast()
      if let end = text.lastIndex(where: { !$0.isWhitespace }) {
        fields["text"] = .string(String(text[...end]))
        blocks.append(.object(fields))
        break
      }
    }
    return blocks.map(ContentBlock.raw)
  }

  /// Where a streaming block's pieces go — `content_block_delta` only
  /// carries an index, so this is remembered from `content_block_start`.
  private enum Target {
    /// One text segment per text block, so the response's segments mirror
    /// the blocks the model produced.
    case text(segmentID: String)
    /// One reasoning entry per thinking block; each block's signature and
    /// record are that entry's alone.
    case thinking(entryID: String)
    case toolUse(id: String, name: String)
    /// A server-side tool call: an empty text segment with the call's id
    /// holds its place among the prose; the block itself is only recorded.
    case serverToolUse(id: String)
    /// Server-side tool results and anything unrecognized: nothing streams to
    /// the framework, the block is only recorded.
    case responseRecordOnly
  }

  /// Relays all channel writes so the first-write callback is handled in
  /// one place instead of at every send site.
  private final class ChannelSink {
    private let channel: LanguageModelExecutorGenerationChannel
    private var pendingFirstWrite: (@Sendable () -> Void)?

    init(
      _ channel: LanguageModelExecutorGenerationChannel,
      onFirstWrite: (@Sendable () -> Void)?
    ) {
      self.channel = channel
      self.pendingFirstWrite = onFirstWrite
    }

    func send(_ event: LanguageModelExecutorGenerationChannel.Event) async {
      pendingFirstWrite?()
      pendingFirstWrite = nil
      await channel.send(event)
    }
  }

  /// Translates one response's stream. Returns the response's stop reason;
  /// `.pauseTurn` means the turn should be continued with another response.
  ///
  /// - Parameter onFirstChannelWrite: Invoked once, immediately before the
  ///   first write to the channel. Events that write nothing (`ping`,
  ///   `message_start`) don't trigger it.
  mutating func translate(
    _ events: AsyncThrowingStream<StreamEvent, Error>,
    into channel: LanguageModelExecutorGenerationChannel,
    onFirstChannelWrite: (@Sendable () -> Void)? = nil
  ) async throws -> StopReason? {
    let channel = ChannelSink(channel, onFirstWrite: onFirstChannelWrite)
    var targets: [Int: Target] = [:]
    var stopReason: StopReason?

    for try await event in events {
      try Task.checkCancellation()
      let completedBlock = assembler.consume(event)

      switch event {
      case .messageStart(let response):
        currentUsage = TurnUsage(usage: response.usage)

      case .contentBlockStart(let index, let block):
        let target = Self.target(for: block)
        targets[index] = target
        if case .toolUse(let id, let name) = target {
          // Opens the call even if no argument deltas follow.
          await channel.send(
            .toolCalls(
              entryID: toolCallsEntryID,
              action: .toolCall(id: id, name: name, action: .appendArguments("", tokenCount: 0))
            )
          )
        }

      case .contentBlockDelta(let index, let delta):
        await send(delta, to: targets[index], via: channel)

      case .contentBlockStop(let index):
        let target = targets.removeValue(forKey: index)
        if let completedBlock { await record(completedBlock, for: target, via: channel) }

      case .messageDelta(let reason, let usage):
        stopReason = reason ?? stopReason
        // Server-tool turns grow the prompt mid-response; message_delta
        // carries updated input-side totals when that happens.
        if usage.inputTokens != nil || usage.cacheReadInputTokens != nil {
          let updated = TurnUsage(usage: usage)
          currentUsage.prompt = updated.prompt
          currentUsage.cached = updated.cached
        }
        currentUsage.output = usage.outputTokens
        let total = settledUsage + currentUsage
        await channel.send(
          .response(
            entryID: responseEntryID,
            action: .updateUsage(
              input: .init(totalTokenCount: total.prompt, cachedTokenCount: total.cached),
              output: .init(totalTokenCount: total.output, reasoningTokenCount: 0)
            )
          )
        )

      case .messageStop, .ping, .unknown:
        break

      case .error(let apiError):
        throw apiError
      }
    }
    // Settled only once the response has been read to the end: a response
    // abandoned partway (and retried) must not count toward the turn.
    settledUsage = settledUsage + currentUsage
    currentUsage = TurnUsage()
    return stopReason
  }

  // MARK: - Private

  private static func target(for block: JSONValue) -> Target {
    switch TurnRecord.Kind(block) {
    case .text: .text(segmentID: UUID().uuidString)
    case .thinking, .redactedThinking: .thinking(entryID: UUID().uuidString)
    case .toolUse(let id, let name): .toolUse(id: id, name: name)
    case .serverToolUse(let id, _, _): .serverToolUse(id: id)
    case .serverToolResult, .other: .responseRecordOnly
    }
  }

  /// Placeholder token count for streamed content deltas. The API reports
  /// usage only at message boundaries, so no real per-delta count exists, and
  /// a count of 0 suppresses partial-snapshot delivery. Authoritative totals
  /// still arrive via `updateUsage` at `message_delta`.
  static let deltaTokenCount = 1

  private func send(
    _ delta: StreamEvent.Delta,
    to target: Target?,
    via channel: ChannelSink
  ) async {
    switch (delta, target) {
    case (.text(let text), .text(let segmentID)) where !text.isEmpty:
      await channel.send(
        .response(
          entryID: responseEntryID,
          action: .appendText(text, segmentID: segmentID, tokenCount: Self.deltaTokenCount)
        )
      )

    case (.thinking(let text), .thinking(let entryID)):
      await channel.send(
        .reasoning(entryID: entryID, action: .appendText(text, tokenCount: Self.deltaTokenCount))
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

    // Everything else — signatures, citations, server-tool input — reaches
    // the framework through the block's record once it completes.
    default:
      break
    }
  }

  /// Files a completed block: into ``content``, and onto the entry it
  /// belongs to.
  private mutating func record(
    _ json: JSONValue,
    for target: Target?,
    via channel: ChannelSink
  ) async {
    let block = TurnRecord.Block(position: content.count, json: json)
    content.append(json)

    switch target {
    case .thinking(let entryID):
      // The entry's signature is the framework's slot for the block's
      // verification bytes.
      let signatureField = if case .redactedThinking = block.kind { "data" } else { "signature" }
      if case .string(let encoded)? = json[signatureField],
        let signature = Data(base64Encoded: encoded)
      {
        await channel.send(
          .reasoning(entryID: entryID, action: .updateSignature(signature, tokenCount: 0))
        )
      }
      await channel.send(
        .reasoning(
          entryID: entryID,
          action: .updateMetadata(TurnRecord.metadata(turn: turn, stored: [block.stored]))
        )
      )

    case .toolUse(let id, let name):
      await channel.send(
        .toolCalls(
          entryID: toolCallsEntryID,
          action: .toolCall(
            id: id,
            name: name,
            action: .updateMetadata(TurnRecord.metadata(turn: turn, stored: [block.stored]))
          )
        )
      )

    case .text, .serverToolUse, .responseRecordOnly, nil:
      responseStored.append(block.stored)
      await channel.send(
        .response(
          entryID: responseEntryID,
          action: .updateMetadata(TurnRecord.metadata(turn: turn, stored: responseStored))
        )
      )
      // The placeholder goes in once its call is on the record, so the
      // snapshot it triggers can already resolve it.
      if case .serverToolUse(let id) = target {
        await channel.send(
          .response(
            entryID: responseEntryID,
            action: .appendText("", segmentID: id, tokenCount: Self.deltaTokenCount)
          )
        )
      }
    }
  }
}

extension EventTranslator.TurnUsage {
  /// `input_tokens` counts only the uncached prompt; cache reads and writes
  /// arrive in separate fields. The framework's total is the whole prompt,
  /// with cache reads as the cached subset.
  fileprivate init(usage: Usage) {
    let cached = usage.cacheReadInputTokens ?? 0
    self.init(
      prompt: (usage.inputTokens ?? 0) + cached + (usage.cacheCreationInputTokens ?? 0),
      cached: cached,
      output: usage.outputTokens
    )
  }
}
