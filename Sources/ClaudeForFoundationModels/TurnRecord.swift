// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

/// Content blocks of an assistant turn as the API sent them, kept in the
/// metadata of the transcript entry that presents them.
///
/// The API wants earlier assistant turns back exactly as it produced them —
/// thinking blocks with their signatures, server-side tool calls and results
/// in place among the text, citations on the text — and the framework's
/// entries can't hold all of that. So each entry the bridge writes carries
/// the blocks it stands for: a reasoning entry its thinking block, each tool
/// call its `tool_use` block, the response entry everything else. Every block
/// is tagged with its position in the turn, so the turn replays in the order
/// it was sent whatever order the entries ended up in.
struct TurnRecord: Sendable, Equatable {
  /// Reserved metadata key on entries the bridge writes. The value is opaque.
  static let metadataKey = "claude.content"

  /// Field names of the stored form.
  private enum Stored {
    static let turn = "turn"
    static let blocks = "blocks"
    static let position = "at"
    static let block = "block"
  }

  struct Block: Sendable, Equatable {
    /// Index among the turn's completed blocks, counted across `pause_turn`
    /// continuations.
    let position: Int
    /// The block object as the API sent it.
    let json: JSONValue
    let kind: Kind

    init(position: Int, json: JSONValue) {
      self.position = position
      self.json = json
      self.kind = Kind(json)
    }

    /// The block's item in the stored form.
    var stored: String {
      JSONValue.object([Stored.position: .number(Double(position)), Stored.block: json]).jsonText
    }
  }

  /// The reading of a block the bridge acts on. Anything it doesn't act on is
  /// `.other` and only ever echoed back.
  enum Kind: Sendable, Equatable {
    case text(String)
    case thinking
    case redactedThinking
    /// A client tool call, answered by the framework.
    case toolUse(id: String, name: String)
    /// A server-side tool call (`server_tool_use`, `mcp_tool_use`, …).
    case serverToolUse(id: String, name: String, input: JSONValue)
    /// The block answering a server-side call (`web_search_tool_result`, …).
    case serverToolResult(type: String, toolUseID: String, content: JSONValue)
    case other

    init(_ json: JSONValue) {
      func string(_ field: String) -> String? {
        if case .string(let value)? = json[field] { value } else { nil }
      }
      let type = string("type") ?? ""
      if type == "text", let text = string("text") {
        self = .text(text)
      } else if type == "thinking" {
        self = .thinking
      } else if type == "redacted_thinking" {
        self = .redactedThinking
      } else if type == "tool_use", let id = string("id"), let name = string("name") {
        self = .toolUse(id: id, name: name)
      } else if type.hasSuffix("_tool_use"), let id = string("id"), let name = string("name") {
        self = .serverToolUse(id: id, name: name, input: json["input"] ?? [:])
      } else if type.hasSuffix("_tool_result"), let toolUseID = string("tool_use_id") {
        self = .serverToolResult(type: type, toolUseID: toolUseID, content: json["content"] ?? nil)
      } else {
        self = .other
      }
    }
  }

  /// Identifies the API turn the positions count within, so entries of
  /// different turns that a transcript leaves side by side stay apart.
  var turn = ""
  var blocks: [Block] = []

  var isEmpty: Bool { blocks.isEmpty }

  /// The entry-metadata value for a record of `turn` whose blocks' stored
  /// items are `stored`, in order: JSON text, so what comes back out is byte
  /// for byte what went in however the transcript is persisted.
  static func metadata(
    turn: String,
    stored: [String]
  ) -> [String: any ConvertibleToGeneratedContent] {
    let turnText = JSONValue.string(turn).jsonText
    return [
      metadataKey:
        "{\"\(Stored.blocks)\":[\(stored.joined(separator: ","))],\"\(Stored.turn)\":\(turnText)}"
    ]
  }
}

extension TurnRecord {
  /// The record an entry carries; empty when it carries none or something
  /// unreadable.
  init(metadata: [String: GeneratedContent]) {
    self.init()
    guard case .string(let text)? = metadata[Self.metadataKey]?.kind,
      let stored = JSONValue.parsed(text), case .string(let turn)? = stored[Stored.turn],
      case .array(let items)? = stored[Stored.blocks]
    else { return }
    self.turn = turn
    blocks = items.compactMap { item in
      guard case .number(let at)? = item[Stored.position], let position = Int(exactly: at),
        let json = item[Stored.block]
      else { return nil }
      return Block(position: position, json: json)
    }
  }

  /// The blocks recorded on a model entry — for a tool-calls entry, on each
  /// of its calls.
  init(of entry: Transcript.Entry) {
    switch entry {
    case .response(let response): self.init(metadata: response.metadata)
    case .reasoning(let reasoning): self.init(metadata: reasoning.metadata)
    case .toolCalls(let calls):
      self.init(blocks: calls.flatMap { Self(metadata: $0.metadata).blocks })
    default: self.init()
    }
  }
}

extension JSONValue {
  /// The framework value as JSON, structurally; a kind this package doesn't
  /// know reads as `null`.
  init(_ content: GeneratedContent) {
    switch content.kind {
    case .null: self = .null
    case .bool(let value): self = .bool(value)
    case .number(let value): self = .number(value)
    case .string(let value): self = .string(value)
    case .array(let values): self = .array(values.map(JSONValue.init))
    case .structure(let properties, _): self = .object(properties.mapValues(JSONValue.init))
    @unknown default: self = .null
    }
  }

  /// Compact JSON text with object keys sorted, so equal values always
  /// produce equal text.
  var jsonText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Encoding a JSONValue cannot fail: every case maps to a JSON value.
    return String(decoding: try! encoder.encode(self), as: UTF8.self)
  }
}
