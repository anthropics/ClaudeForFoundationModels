// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Rebuilds a streamed response's content blocks — the objects a
/// non-streaming response's `content` array would have carried — so they
/// can be sent back to the API as received. Blocks are kept as the JSON
/// objects the API sent, with the streamed pieces (text, tool input,
/// citations, signatures) folded in.
///
/// Block indices are scoped to one response; `message_start` begins a new
/// one, so a single assembler can be fed a turn's `pause_turn`
/// continuations back to back.
package struct ContentAssembler: Sendable {
  /// Blocks of the current response that have started but not stopped,
  /// keyed by their index within that response.
  private var open: [Int: OpenBlock] = [:]

  private struct OpenBlock {
    var fields: [String: JSONValue]
    /// The field text and thinking deltas accumulate into, if this block
    /// has one; the accumulated value is written back when the block closes.
    let streamedKey: String?
    var streamed: String
    var partialInput = ""

    init(fields: [String: JSONValue]) {
      self.fields = fields
      switch fields["type"] {
      case "text": streamedKey = "text"
      case "thinking": streamedKey = "thinking"
      default: streamedKey = nil
      }
      streamed =
        if let streamedKey, case .string(let initial)? = fields[streamedKey] { initial } else { "" }
    }

    mutating func apply(_ delta: StreamEvent.Delta) {
      switch delta {
      case .text(let fragment), .thinking(let fragment):
        streamed += fragment
      case .signature(let signature):
        fields["signature"] = .string(signature)
      case .inputJSON(let fragment):
        partialInput += fragment
      case .citation(let citation):
        var citations: [JSONValue] =
          if case .array(let existing)? = fields["citations"] { existing } else { [] }
        citations.append(citation)
        fields["citations"] = .array(citations)
      case .unknown:
        break
      }
    }

    /// The block as the API would report it, or `nil` for a text block that
    /// received no text — the API rejects an empty text block in a request.
    var closed: JSONValue? {
      var fields = fields
      if let streamedKey {
        if streamedKey == "text", streamed.isEmpty { return nil }
        fields[streamedKey] = .string(streamed)
      }
      if !partialInput.isEmpty, let input = JSONValue.parsed(partialInput) {
        fields["input"] = input
      }
      return .object(fields)
    }
  }

  package init() {}

  /// Folds one event in. Returns the block the event completed, if any.
  package mutating func consume(_ event: StreamEvent) -> JSONValue? {
    switch event {
    case .messageStart:
      open = [:]
    case .contentBlockStart(let index, let block):
      if case .object(let fields) = block { open[index] = OpenBlock(fields: fields) }
    case .contentBlockDelta(let index, let delta):
      open[index]?.apply(delta)
    case .contentBlockStop(let index):
      return open.removeValue(forKey: index)?.closed
    case .messageDelta, .messageStop, .ping, .error, .unknown:
      break
    }
    return nil
  }
}
