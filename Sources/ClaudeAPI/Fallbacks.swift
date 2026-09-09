// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// `fallbacks`: substitute models the API tries, in order, when the requested
/// model declines for policy reasons. The request needs the
/// ``Fallbacks/betaHeader`` opt-in.
package enum Fallbacks: Sendable, Hashable, Codable {
  /// Each entry names a model, plus any request field that model needs to be
  /// different from the request's own.
  case models([Fallback])
  /// The requested model's server-defined fallback configuration (`"default"`).
  case serverDefault

  /// The `anthropic-beta` value that enables a list of `fallbacks`. The
  /// `fallback` blocks that a response carries at each model boundary parse
  /// only under a fallbacks opt-in, so a request that replays one sends this
  /// value too.
  package static let betaHeader = "server-side-fallback-2026-06-01"

  /// The `anthropic-beta` value that ``serverDefault`` needs. It also accepts
  /// everything ``betaHeader`` does. Each form of `fallbacks` sends the
  /// narrowest value that admits it.
  package static let defaultRoutingBetaHeader = "server-side-fallback-2026-07-01"

  /// The `anthropic-beta` value that a request with these fallbacks needs.
  package var requiredBeta: String {
    if case .serverDefault = self { Self.defaultRoutingBetaHeader } else { Self.betaHeader }
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let keyword = try? container.decode(String.self) {
      guard keyword == "default" else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Unknown fallbacks keyword '\(keyword)'"
        )
      }
      self = .serverDefault
    } else {
      self = .models(try container.decode([Fallback].self))
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .models(let entries): try container.encode(entries)
    case .serverDefault: try container.encode("default")
    }
  }
}

/// One `fallbacks` entry. Under ``Fallbacks/betaHeader``, an override
/// replaces the request's whole field for this model. A missing or `null`
/// override keeps the request's value, so a field can't be unset, and an
/// override is always a complete value.
package struct Fallback: Sendable, Hashable, Codable {
  package var model: String
  /// This model's `thinking`, in place of the request's.
  package var thinking: ThinkingConfig?
  /// This model's whole `output_config`, in place of the request's. It
  /// carries the request's `format` as well as this model's `effort`.
  package var outputConfig: OutputConfig?

  package init(
    model: String,
    thinking: ThinkingConfig? = nil,
    outputConfig: OutputConfig? = nil
  ) {
    self.model = model
    self.thinking = thinking
    self.outputConfig = outputConfig
  }

  private enum CodingKeys: String, CodingKey {
    case model, thinking
    case outputConfig = "output_config"
  }
}
