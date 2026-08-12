// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

extension ClaudeServerToolActivity {
  /// One activity per server-side tool call among `blocks`, in order, with
  /// the result block answering it (if it's among `blocks`) folded in. A
  /// result whose call isn't among `blocks` is skipped.
  static func derive(from blocks: [TurnRecord.Block]) -> [ClaudeServerToolActivity] {
    var calls: [(id: String, name: String, input: JSONValue)] = []
    var results: [String: Content.ToolResult] = [:]
    for block in blocks {
      switch block.kind {
      case .serverToolUse(let id, let name, let input):
        calls.append((id, name, input))
      case .serverToolResult(let type, let toolUseID, let content):
        results[toolUseID] = (type, content)
      default:
        break
      }
    }
    return calls.map { call in
      ClaudeServerToolActivity(
        id: call.id,
        content: Content(toolName: call.name, input: call.input, result: results[call.id])
      )
    }
  }
}

extension ClaudeServerToolActivity.Content {
  /// Typed reading of a call and, once it has arrived, its result. A tool
  /// this package doesn't model, or a payload that doesn't decode as the
  /// tool's documented shape, reads as `.unrecognized`.
  init(toolName: String, input: JSONValue, result: ToolResult?) {
    switch toolName {
    case ClaudeServerTool.Name.webSearch:
      if let call: WebSearchInput = input.decoded(),
        let outcome = Self.outcome(
          of: result,
          expecting: "web_search_tool_result",
          ClaudeServerToolActivity.WebSearch.Outcome.init(payload:)
        )
      {
        self = .webSearch(.init(query: call.query, outcome: outcome))
        return
      }
    case ClaudeServerTool.Name.webFetch:
      if let call: WebFetchInput = input.decoded(),
        let outcome = Self.outcome(
          of: result,
          expecting: "web_fetch_tool_result",
          ClaudeServerToolActivity.WebFetch.Outcome.init(payload:)
        )
      {
        self = .webFetch(.init(url: call.url, outcome: outcome))
        return
      }
    case ClaudeServerTool.Name.codeExecution:
      if let call: CodeExecutionInput = input.decoded(),
        let outcome = Self.outcome(
          of: result,
          expecting: "code_execution_tool_result",
          ClaudeServerToolActivity.CodeExecution.Outcome.init(payload:)
        )
      {
        self = .codeExecution(.init(code: call.code, outcome: outcome))
        return
      }
    default:
      break
    }
    self = .unrecognized(.init(toolName: toolName, resultType: result?.type))
  }

  typealias ToolResult = (type: String, payload: JSONValue)

  /// `.some(nil)` while no result has arrived, `.some(outcome)` for one that
  /// decodes, and `nil` for one that doesn't.
  private static func outcome<Outcome>(
    of result: ToolResult?,
    expecting type: String,
    _ decode: (JSONValue) -> Outcome?
  ) -> Outcome?? {
    guard let result else { return .some(nil) }
    guard result.type == type, let outcome = decode(result.payload) else { return nil }
    return .some(outcome)
  }

  var toolName: String {
    switch self {
    case .webSearch: ClaudeServerTool.Name.webSearch
    case .webFetch: ClaudeServerTool.Name.webFetch
    case .codeExecution: ClaudeServerTool.Name.codeExecution
    case .unrecognized(let unrecognized): unrecognized.toolName
    }
  }
}

/// Every server tool reports a failure the same way, as a
/// `*_tool_result_error` object; anything else is the tool's own result shape.
private func decodeOutcome<Outcome, Wire: Decodable>(
  _ payload: JSONValue,
  failure: (String) -> Outcome,
  success: (Wire) -> Outcome
) -> Outcome? {
  if case .string(let type)? = payload["type"], type.hasSuffix("_error") {
    return (payload.decoded() as WireError?).map { failure($0.errorCode) }
  }
  return (payload.decoded() as Wire?).map(success)
}

extension ClaudeServerToolActivity.WebSearch.Outcome {
  fileprivate init?(payload: JSONValue) {
    guard
      let outcome = decodeOutcome(
        payload,
        failure: Self.failure(errorCode:),
        success: { (hits: [WebSearchHitWire]) in
          // A hit whose URL doesn't parse is dropped rather than sinking the
          // whole result set.
          .results(
            hits.compactMap { hit in
              URL(string: hit.url)
                .map {
                  .init(url: $0, title: hit.title ?? $0.absoluteString, pageAge: hit.pageAge)
                }
            }
          )
        }
      )
    else { return nil }
    self = outcome
  }
}

extension ClaudeServerToolActivity.WebFetch.Outcome {
  fileprivate init?(payload: JSONValue) {
    guard
      let outcome = decodeOutcome(
        payload,
        failure: Self.failure(errorCode:),
        success: { (result: WebFetchResultWire) in
          .document(
            .init(
              url: result.url,
              title: result.content?.title,
              text: result.content?.source?.data,
              mediaType: result.content?.source?.mediaType,
              retrievedAt: result.retrievedAt
            )
          )
        }
      )
    else { return nil }
    self = outcome
  }
}

extension ClaudeServerToolActivity.CodeExecution.Outcome {
  fileprivate init?(payload: JSONValue) {
    guard
      let outcome = decodeOutcome(
        payload,
        failure: Self.failure(errorCode:),
        success: { (result: CodeExecutionResultWire) in
          .output(
            .init(stdout: result.stdout, stderr: result.stderr, returnCode: result.returnCode)
          )
        }
      )
    else { return nil }
    self = outcome
  }
}

// MARK: - Wire shapes

private struct WebSearchInput: Decodable {
  var query: String
}

private struct WebFetchInput: Decodable {
  var url: URL
}

private struct CodeExecutionInput: Decodable {
  var code: String
}

/// `{"type": "*_tool_result_error", "error_code": ...}` — the failure shape
/// shared by every server tool's result block.
private struct WireError: Decodable {
  var errorCode: String

  enum CodingKeys: String, CodingKey {
    case errorCode = "error_code"
  }
}

private struct WebSearchHitWire: Decodable {
  var url: String
  var title: String?
  var pageAge: String?

  enum CodingKeys: String, CodingKey {
    case url, title
    case pageAge = "page_age"
  }
}

private struct WebFetchResultWire: Decodable {
  var url: URL?
  var retrievedAt: String?
  var content: Document?

  enum CodingKeys: String, CodingKey {
    case url, content
    case retrievedAt = "retrieved_at"
  }

  struct Document: Decodable {
    var title: String?
    var source: Source?

    struct Source: Decodable {
      var data: String?
      var mediaType: String?

      enum CodingKeys: String, CodingKey {
        case data
        case mediaType = "media_type"
      }
    }
  }
}

private struct CodeExecutionResultWire: Decodable {
  var stdout: String?
  var stderr: String?
  var returnCode: Int?

  enum CodingKeys: String, CodingKey {
    case stdout, stderr
    case returnCode = "return_code"
  }
}
