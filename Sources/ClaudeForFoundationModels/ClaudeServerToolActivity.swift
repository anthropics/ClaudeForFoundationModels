// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels

/// One server-side tool round-trip (web search, web fetch, code execution)
/// the model made while producing a response.
///
/// A response's segments run in the order the model produced them: prose in
/// text segments and, wherever the model called a server-side tool, an empty
/// text segment holding that call's place. Ask the response which it is with
/// ``FoundationModels/Transcript/Response/claudeServerToolActivity(for:)``;
/// ``FoundationModels/Transcript/claudeServerToolActivity`` lists every
/// round-trip in a conversation.
///
/// Each tool's `outcome` is `nil` while the call is still running, and stays
/// `nil` for a call whose turn ended before the result arrived.
///
/// ```swift
/// for segment in response.segments {
///   if let activity = response.claudeServerToolActivity(for: segment) {
///     if case .webSearch(let search) = activity.content { showSearch(search) }
///   } else if case .text(let text) = segment {
///     showProse(text.content)
///   }
/// }
/// ```
public struct ClaudeServerToolActivity: Sendable, Equatable, Identifiable {
  /// The API's tool-use id, shared by the call and its result.
  public let id: String
  public let content: Content

  public enum Content: Sendable, Equatable {
    case webSearch(WebSearch)
    case webFetch(WebFetch)
    case codeExecution(CodeExecution)
    /// A tool this package has no typed reading of, or one whose call or
    /// result arrived in a shape the typed reading couldn't decode.
    case unrecognized(Unrecognized)
  }

  /// The tool's API name, e.g. `web_search`.
  public var toolName: String { content.toolName }

  // MARK: - Web search

  public struct WebSearch: Sendable, Equatable {
    /// The search query the model issued.
    public let query: String
    public let outcome: Outcome?

    public enum Outcome: Sendable, Equatable {
      case results([Hit])
      /// e.g. `max_uses_exceeded`.
      case failure(errorCode: String)
    }

    public struct Hit: Sendable, Equatable {
      public let url: URL
      public let title: String
      /// Content age as reported by the search index, e.g. "April 30, 2026".
      public let pageAge: String?
    }
  }

  // MARK: - Web fetch

  public struct WebFetch: Sendable, Equatable {
    /// The URL the model fetched.
    public let url: URL
    public let outcome: Outcome?

    public enum Outcome: Sendable, Equatable {
      case document(Document)
      /// e.g. `url_not_allowed`.
      case failure(errorCode: String)
    }

    public struct Document: Sendable, Equatable {
      /// The resolved URL, when the API reports one (e.g. after redirects).
      public let url: URL?
      public let title: String?
      /// The document's content — text, or base64 for binary media.
      public let text: String?
      /// The content's media type, e.g. `text/plain` or `application/pdf`.
      /// `nil` means plain text.
      public let mediaType: String?
      /// When the page was retrieved (ISO 8601), as reported by the API.
      public let retrievedAt: String?
    }
  }

  // MARK: - Code execution

  public struct CodeExecution: Sendable, Equatable {
    /// The code the model ran in Anthropic's sandbox.
    public let code: String
    public let outcome: Outcome?

    public enum Outcome: Sendable, Equatable {
      case output(Output)
      /// e.g. `unavailable`.
      case failure(errorCode: String)
    }

    public struct Output: Sendable, Equatable {
      public let stdout: String?
      public let stderr: String?
      public let returnCode: Int?
    }
  }

  // MARK: - Unrecognized

  public struct Unrecognized: Sendable, Equatable {
    public let toolName: String
    /// The result's block type, e.g. `some_tool_result`; `nil` until the
    /// result arrives.
    public let resultType: String?
  }
}

extension Transcript.Response {
  /// The server-side tool round-trip `segment` holds the place of, or `nil`
  /// for an ordinary segment.
  ///
  /// The placeholder is an empty text segment whose id is the API's tool-use
  /// id. Its outcome fills in when the result arrives in this response; a
  /// result that only arrived in a later one (the model had called one of
  /// your tools alongside) is paired up by
  /// ``FoundationModels/Transcript/claudeServerToolActivity`` instead.
  public func claudeServerToolActivity(for segment: Transcript.Segment) -> ClaudeServerToolActivity?
  {
    guard case .text(let placeholder) = segment, placeholder.content.isEmpty else { return nil }
    let pair = TurnRecord(metadata: metadata).blocks
      .filter { block in
        switch block.kind {
        case .serverToolUse(placeholder.id, _, _), .serverToolResult(_, placeholder.id, _): true
        default: false
        }
      }
    return ClaudeServerToolActivity.derive(from: pair).first
  }
}

extension Transcript {
  /// Every server-tool round-trip in the conversation, in order, with each
  /// result paired to its call wherever the two arrived. Derived from the
  /// transcript on each access.
  public var claudeServerToolActivity: [ClaudeServerToolActivity] {
    ClaudeServerToolActivity.derive(
      from: flatMap { entry -> [TurnRecord.Block] in
        guard case .response(let response) = entry else { return [] }
        return TurnRecord(metadata: response.metadata).blocks
      }
    )
  }
}
