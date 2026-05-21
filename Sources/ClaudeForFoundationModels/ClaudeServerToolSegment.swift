// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels

/// One server-side tool round-trip (web search, web fetch, code execution),
/// surfaced in the transcript as a custom segment.
///
/// A segment appears when the model invokes the tool and is updated in place
/// when the result arrives — the result field is `nil` only while the call is
/// still in flight mid-stream.
///
/// ```swift
/// if case .custom(let custom) = segment,
///   let activity = custom as? ClaudeServerToolSegment
/// {
///   switch activity.content {
///   case .webSearch(let search):
///     showQuery(search.query)
///     if let results = search.results { showHits(results) }
///   default: break
///   }
/// }
/// ```
public struct ClaudeServerToolSegment: Transcript.CustomSegment {
  public let id: String
  public let content: Content

  public enum Content: Sendable, Equatable, Codable {
    case webSearch(WebSearch)
    case webFetch(WebFetch)
    case codeExecution(CodeExecution)
    /// A server tool this package version doesn't model. Its payloads are
    /// preserved verbatim and still replay on later turns.
    case unrecognized(UnrecognizedActivity)
  }

  public init(id: String, content: Content) {
    self.id = id
    self.content = content
  }

  // MARK: - Web search

  public struct WebSearch: Sendable, Equatable, Codable {
    /// The search query the model issued.
    public var query: String
    /// `nil` while the search is in flight.
    public var outcome: Outcome?

    public init(query: String, outcome: Outcome? = nil) {
      self.query = query
      self.outcome = outcome
    }

    public enum Outcome: Sendable, Equatable, Codable {
      case results([Hit])
      /// e.g. `max_uses_exceeded`.
      case failure(errorCode: String)
    }

    public struct Hit: Sendable, Equatable, Codable {
      public var url: URL
      public var title: String
      /// Content age as reported by the search index, e.g. "April 30, 2026".
      public var pageAge: String?
      /// Opaque token the API requires back on later turns to cite this
      /// hit. Carried so multi-turn replay keeps citations working.
      public var encryptedContent: String?

      public init(
        url: URL,
        title: String,
        pageAge: String? = nil,
        encryptedContent: String? = nil
      ) {
        self.url = url
        self.title = title
        self.pageAge = pageAge
        self.encryptedContent = encryptedContent
      }

      private enum CodingKeys: String, CodingKey {
        case type, url, title
        case pageAge = "page_age"
        case encryptedContent = "encrypted_content"
      }

      public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        pageAge = try c.decodeIfPresent(String.self, forKey: .pageAge)
        encryptedContent = try c.decodeIfPresent(String.self, forKey: .encryptedContent)
      }

      public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("web_search_result", forKey: .type)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(pageAge, forKey: .pageAge)
        try c.encodeIfPresent(encryptedContent, forKey: .encryptedContent)
      }
    }
  }

  // MARK: - Web fetch

  public struct WebFetch: Sendable, Equatable, Codable {
    /// The URL the model fetched.
    public var url: URL
    /// `nil` while the fetch is in flight.
    public var outcome: Outcome?

    public init(url: URL, outcome: Outcome? = nil) {
      self.url = url
      self.outcome = outcome
    }

    public enum Outcome: Sendable, Equatable, Codable {
      case document(Document)
      /// e.g. `url_not_allowed`.
      case failure(errorCode: String)
    }

    public struct Document: Sendable, Equatable, Codable {
      /// The resolved URL, when the API reports one (e.g. after redirects).
      public var url: URL?
      /// The document's title, when the page had one.
      public var title: String?
      /// The document's content — text, or base64 for binary media.
      public var text: String?
      /// The content's media type, e.g. `text/plain` or `application/pdf`.
      /// `nil` means plain text. Carried so non-text documents replay with
      /// their original encoding instead of being re-labeled as text.
      public var mediaType: String?
      /// When the page was retrieved (ISO 8601), as reported by the API.
      public var retrievedAt: String?

      public init(
        url: URL? = nil,
        title: String? = nil,
        text: String? = nil,
        mediaType: String? = nil,
        retrievedAt: String? = nil
      ) {
        self.url = url
        self.title = title
        self.text = text
        self.mediaType = mediaType
        self.retrievedAt = retrievedAt
      }
    }
  }

  // MARK: - Code execution

  public struct CodeExecution: Sendable, Equatable, Codable {
    /// The code the model ran in Anthropic's sandbox.
    public var code: String
    /// `nil` while execution is in flight.
    public var outcome: Outcome?

    public init(code: String, outcome: Outcome? = nil) {
      self.code = code
      self.outcome = outcome
    }

    public enum Outcome: Sendable, Equatable, Codable {
      case output(Output)
      /// e.g. `unavailable`.
      case failure(errorCode: String)
    }

    public struct Output: Sendable, Equatable, Codable {
      public var stdout: String?
      public var stderr: String?
      public var returnCode: Int?
      /// Opaque encrypted stdout the agentic search flow returns in place of
      /// plain `stdout`. Carried so multi-turn replay stays verifiable.
      public var encryptedStdout: String?

      public init(
        stdout: String? = nil,
        stderr: String? = nil,
        returnCode: Int? = nil,
        encryptedStdout: String? = nil
      ) {
        self.stdout = stdout
        self.stderr = stderr
        self.returnCode = returnCode
        self.encryptedStdout = encryptedStdout
      }
    }
  }

  // MARK: - Unrecognized

  public struct UnrecognizedActivity: Sendable, Equatable, Codable {
    /// Tool name, e.g. a server tool newer than this package.
    public var toolName: String
    /// The invocation's verbatim JSON input, when one was seen.
    public var callJSON: String?
    /// The result's wire block type, e.g. `some_tool_result`.
    public var resultType: String?
    /// The result's verbatim JSON payload, when one has arrived.
    public var resultJSON: String?

    public init(
      toolName: String,
      callJSON: String? = nil,
      resultType: String? = nil,
      resultJSON: String? = nil
    ) {
      self.toolName = toolName
      self.callJSON = callJSON
      self.resultType = resultType
      self.resultJSON = resultJSON
    }

    /// The invocation input, readable via `GeneratedContent`'s accessors.
    public var call: GeneratedContent? {
      callJSON.flatMap { try? GeneratedContent(json: $0) }
    }
    /// The result payload, readable via `GeneratedContent`'s accessors.
    public var result: GeneratedContent? {
      resultJSON.flatMap { try? GeneratedContent(json: $0) }
    }
  }

  public var toolName: String { content.wireToolName }

  // MARK: - Renderings

  public var description: String {
    switch content {
    case .webSearch(let search):
      switch search.outcome {
      case .results(let hits):
        "[web_search \"\(search.query)\"] "
          + hits.map(\.url.absoluteString).joined(separator: ", ")
      case .failure(let errorCode):
        "[web_search \"\(search.query)\"] error: \(errorCode)"
      case nil:
        "[web_search \"\(search.query)\"] in progress"
      }
    case .webFetch(let fetch):
      switch fetch.outcome {
      case .document, nil:
        "[web_fetch \(fetch.url.absoluteString)]"
      case .failure(let errorCode):
        "[web_fetch \(fetch.url.absoluteString)] error: \(errorCode)"
      }
    case .codeExecution(let execution):
      switch execution.outcome {
      case .output(let output):
        "[code_execution] exit \(output.returnCode.map(String.init) ?? "?")"
          + (output.stdout.map { " — \($0)" } ?? "")
      case .failure(let errorCode):
        "[code_execution] error: \(errorCode)"
      case nil:
        "[code_execution] running"
      }
    case .unrecognized(let activity):
      "[\(activity.toolName)] \(activity.resultJSON ?? activity.callJSON ?? "")"
    }
  }

  public var promptRepresentation: Prompt { Prompt(description) }
  public var instructionsRepresentation: Instructions { Instructions(description) }
}
