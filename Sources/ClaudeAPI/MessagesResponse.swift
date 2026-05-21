// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Response body for `POST /v1/messages`. When streaming, the same shape
/// arrives as the `message_start` payload, with `content` empty and `usage`
/// carrying the prompt-side counts.
package struct MessagesResponse: Sendable, Codable {
  package var id: String
  package var model: String
  package var role: Message.Role
  package var content: [ContentBlock]
  package var stopReason: StopReason?
  package var usage: Usage

  private enum CodingKeys: String, CodingKey {
    case id, model, role, content, usage
    case stopReason = "stop_reason"
  }
}

package enum StopReason: String, Sendable, Codable {
  case endTurn = "end_turn"
  case maxTokens = "max_tokens"
  case stopSequence = "stop_sequence"
  case toolUse = "tool_use"
  case refusal
  case pauseTurn = "pause_turn"
  /// Forward-compatibility: an unrecognized stop reason must not kill the
  /// stream after content has already been delivered.
  case unknown

  package init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = StopReason(rawValue: raw) ?? .unknown
  }
}

/// Token counts as the API reports them: `inputTokens` covers only the
/// uncached portion of the prompt — cache reads and writes are separate
/// fields, so the full prompt size is the sum of all three.
package struct Usage: Sendable, Codable, Hashable {
  package var inputTokens: Int?
  package var outputTokens: Int
  package var cacheCreationInputTokens: Int?
  package var cacheReadInputTokens: Int?

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
  }
}
