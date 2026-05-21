// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Server-sent event payloads from `POST /v1/messages` with `stream: true`.
package enum StreamEvent: Sendable, Decodable {
  case messageStart(MessagesResponse)
  case contentBlockStart(index: Int, block: ContentBlock)
  case contentBlockDelta(index: Int, delta: Delta)
  case contentBlockStop(index: Int)
  case messageDelta(stopReason: StopReason?, usage: Usage)
  case messageStop
  case ping
  case error(APIError)
  /// Forward-compat: unrecognized event types are surfaced, not thrown,
  /// so a new API feature doesn't break existing clients.
  case unknown(type: String)

  package enum Delta: Sendable, Decodable {
    case text(String)
    case inputJSON(String)
    case thinking(String)
    case signature(String)
    /// Forward-compat: unrecognized delta types are surfaced, not thrown.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
      case type, text, thinking, signature
      case partialJSON = "partial_json"
    }

    package init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let type = try c.decode(String.self, forKey: .type)
      switch type {
      case "text_delta":
        self = .text(try c.decode(String.self, forKey: .text))
      case "input_json_delta":
        self = .inputJSON(try c.decode(String.self, forKey: .partialJSON))
      case "thinking_delta":
        self = .thinking(try c.decode(String.self, forKey: .thinking))
      case "signature_delta":
        self = .signature(try c.decode(String.self, forKey: .signature))
      default:
        self = .unknown(type: type)
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type, index, message, delta, usage, error
    case contentBlock = "content_block"
  }

  private struct MessageDeltaPayload: Decodable {
    var stopReason: StopReason?
    private enum CodingKeys: String, CodingKey { case stopReason = "stop_reason" }
  }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "message_start":
      self = .messageStart(try c.decode(MessagesResponse.self, forKey: .message))
    case "content_block_start":
      self = .contentBlockStart(
        index: try c.decode(Int.self, forKey: .index),
        block: try c.decode(ContentBlock.self, forKey: .contentBlock)
      )
    case "content_block_delta":
      self = .contentBlockDelta(
        index: try c.decode(Int.self, forKey: .index),
        delta: try c.decode(Delta.self, forKey: .delta)
      )
    case "content_block_stop":
      self = .contentBlockStop(index: try c.decode(Int.self, forKey: .index))
    case "message_delta":
      let d = try c.decode(MessageDeltaPayload.self, forKey: .delta)
      self = .messageDelta(
        stopReason: d.stopReason,
        usage: try c.decode(Usage.self, forKey: .usage)
      )
    case "message_stop":
      self = .messageStop
    case "ping":
      self = .ping
    case "error":
      self = .error(try c.decode(APIError.self, forKey: .error))
    case let other:
      self = .unknown(type: other)
    }
  }
}
