// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

/// A handover within a response: the point where one model declined and a
/// fallback model took over.
///
/// The response's segments run in the order the models produced them. At
/// each handover, an empty text segment holds the handover's place. The
/// declining model's partial text comes before that segment, and the
/// fallback model's continuation comes after it. Ask the response which
/// segment is the handover with
/// ``FoundationModels/Transcript/Response/claudeHandover(for:)``.
///
/// ```swift
/// if let handover = response.claudeHandovers.last {
///   showNote("Finished by \(handover.toModelID)")
/// }
/// ```
public struct ClaudeModelHandover: Sendable, Equatable {
  /// The ID of the model that declined. Its output ends here.
  public let fromModelID: String
  /// The ID of the fallback model that produced the output that follows.
  public let toModelID: String
  /// Why the declining model handed over, or `nil` when the API doesn't say.
  public let reason: Reason?

  public enum Reason: Sendable, Equatable {
    /// The declining model refused for policy reasons. `category` is the
    /// API's name for the policy area (for example `cyber` or `bio`), or
    /// `nil` when the API doesn't give one.
    case refusal(category: String?)
    /// A reason this package doesn't model, by its API `type`.
    case unrecognized(type: String)
  }

  init?(_ kind: TurnRecord.Kind) {
    guard case .fallback(let from, let to, let trigger) = kind else { return nil }
    fromModelID = from
    toModelID = to
    switch trigger["type"] {
    case .string("refusal")?:
      if case .string(let category)? = trigger["category"] {
        reason = .refusal(category: category)
      } else {
        reason = .refusal(category: nil)
      }
    case .string(let type)?:
      reason = .unrecognized(type: type)
    default:
      reason = nil
    }
  }

  /// The ID of the empty text segment that holds the place of the handover
  /// recorded at `position` in `turn`. A `fallback` block carries no ID of
  /// its own, and the recorded block must go back to the API exactly as it
  /// was sent, so the ID is derived from where the block was recorded.
  static func segmentID(turn: String, position: Int) -> String {
    "claude.fallback.\(turn).\(position)"
  }
}

extension Transcript.Response {
  /// The handover that `segment` holds the place of, or `nil` for an ordinary
  /// segment.
  public func claudeHandover(for segment: Transcript.Segment) -> ClaudeModelHandover? {
    guard case .text(let placeholder) = segment, placeholder.content.isEmpty else { return nil }
    let record = TurnRecord(metadata: metadata)
    let block = record.blocks.first { block in
      ClaudeModelHandover.segmentID(turn: record.turn, position: block.position) == placeholder.id
    }
    return block.flatMap { ClaudeModelHandover($0.kind) }
  }

  /// Every handover in this response, in order. Empty when one model produced
  /// the whole response.
  public var claudeHandovers: [ClaudeModelHandover] {
    TurnRecord(metadata: metadata).blocks.compactMap { ClaudeModelHandover($0.kind) }
  }

  /// The ID of the model that served this response, as the API reported it.
  /// After a handover, this is the fallback model that finished the response.
  /// Without one, it's the model the API started the response on. That is a
  /// fallback model when the API routed the request straight to it. The value
  /// is `nil` when this package didn't record the response.
  public var claudeModelID: String? {
    let record = TurnRecord(metadata: metadata)
    return record.blocks.compactMap { ClaudeModelHandover($0.kind) }.last?.toModelID ?? record.model
  }
}
