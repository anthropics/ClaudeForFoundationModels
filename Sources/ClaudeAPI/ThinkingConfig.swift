// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Extended-thinking configuration. Adaptive is the only on-mode for current
/// Opus models; older models accept a fixed budget but that path is deprecated.
package enum ThinkingConfig: Sendable, Hashable, Codable {
  case adaptive(display: Display?)
  case disabled

  /// `thinking.display` — whether thinking blocks carry readable text.
  /// On Sonnet 5 and Opus 4.7+ the API default is `omitted`, which streams
  /// thinking blocks with empty text; `summarized` restores readable
  /// reasoning. Visibility only — thinking is billed the same either way.
  package enum Display: String, Sendable, Codable {
    case summarized
    case omitted
  }

  private enum CodingKeys: String, CodingKey { case type, display }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "adaptive":
      self = .adaptive(display: try c.decodeIfPresent(Display.self, forKey: .display))
    case "disabled": self = .disabled
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: c,
        debugDescription: "Unknown thinking type '\(other)'"
      )
    }
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .adaptive(let display):
      try c.encode("adaptive", forKey: .type)
      try c.encodeIfPresent(display, forKey: .display)
    case .disabled:
      try c.encode("disabled", forKey: .type)
    }
  }
}

/// Prompt-cache opt-in (`cache_control`). Always `ephemeral` on the wire;
/// `ttl` selects the cache window, with the API's default when nil.
package struct CacheControl: Sendable, Hashable, Codable {
  package enum TTL: String, Sendable, Codable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
  }

  package var ttl: TTL?
  package init(ttl: TTL? = nil) { self.ttl = ttl }

  private enum CodingKeys: String, CodingKey { case type, ttl }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ttl = try c.decodeIfPresent(TTL.self, forKey: .ttl)
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode("ephemeral", forKey: .type)
    try c.encodeIfPresent(ttl, forKey: .ttl)
  }
}
