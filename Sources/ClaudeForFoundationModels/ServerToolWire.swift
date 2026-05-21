// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation

// Wire bridging for ClaudeServerToolSegment: parsing stream payloads into the
// typed content, attaching results to in-flight calls, and replaying both
// halves of the round-trip as request blocks on later turns.

extension ClaudeServerToolSegment.Content {
  /// Typed parse of a `server_tool_use` block's input. Unknown tools and
  /// undecodable inputs land in `.unrecognized` rather than being dropped.
  init(callToolName toolName: String, input: JSONValue) {
    switch toolName {
    case "web_search":
      if let call: WebSearchInput = input.decoded() {
        self = .webSearch(.init(query: call.query))
        return
      }
    case "web_fetch":
      if let call: WebFetchInput = input.decoded() {
        self = .webFetch(.init(url: call.url))
        return
      }
    case "code_execution":
      if let call: CodeExecutionInput = input.decoded() {
        self = .codeExecution(.init(code: call.code))
        return
      }
    default:
      break
    }
    self = .unrecognized(.init(toolName: toolName, callJSON: input.jsonText))
  }

  /// Attaches a `*_tool_result` payload to this call. Result shapes that
  /// don't decode demote the whole segment to `.unrecognized` so nothing is
  /// silently lost.
  func merging(resultType: String, payload: JSONValue) -> Self {
    switch (self, resultType) {
    case (.webSearch(var search), "web_search_tool_result"):
      if let error: WireError = payload.decoded() {
        search.outcome = .failure(errorCode: error.errorCode)
        return .webSearch(search)
      }
      if let hits: [ClaudeServerToolSegment.WebSearch.Hit] = payload.decoded() {
        search.outcome = .results(hits)
        return .webSearch(search)
      }

    case (.webFetch(var fetch), "web_fetch_tool_result"):
      if let error: WireError = payload.decoded() {
        fetch.outcome = .failure(errorCode: error.errorCode)
        return .webFetch(fetch)
      }
      if let result: WebFetchResultWire = payload.decoded() {
        fetch.outcome = .document(
          .init(
            url: result.url,
            title: result.content?.title,
            text: result.content?.source?.data,
            mediaType: result.content?.source?.mediaType,
            retrievedAt: result.retrievedAt
          )
        )
        return .webFetch(fetch)
      }

    case (.codeExecution(var execution), "code_execution_tool_result"):
      if let error: WireError = payload.decoded() {
        execution.outcome = .failure(errorCode: error.errorCode)
        return .codeExecution(execution)
      }
      if let result: CodeExecutionResultWire = payload.decoded() {
        execution.outcome = .output(
          .init(
            stdout: result.stdout,
            stderr: result.stderr,
            returnCode: result.returnCode,
            encryptedStdout: result.encryptedStdout
          )
        )
        return .codeExecution(execution)
      }

    case (.unrecognized(var activity), _):
      activity.resultType = resultType
      activity.resultJSON = payload.jsonText
      return .unrecognized(activity)

    default:
      break
    }
    return .unrecognized(
      .init(
        toolName: wireToolName,
        callJSON: callPayload.jsonText,
        resultType: resultType,
        resultJSON: payload.jsonText
      )
    )
  }

  /// The round-trip as request content blocks. The API rejects an unpaired
  /// call or result outright, so a half-seen round trip (cancelled mid-tool,
  /// stream cut before the result) replays as nothing rather than wedging
  /// every subsequent request with a hard 400.
  func wireBlocks(id: String) -> [ContentBlock] {
    let sawCall =
      if case .unrecognized(let activity) = self { activity.callJSON != nil } else { true }
    guard sawCall, let result = resultWire else { return [] }
    return [
      .serverToolUse(id: id, name: wireToolName, input: callPayload),
      .serverToolResult(toolUseID: id, type: result.type, content: result.payload),
    ]
  }

  // MARK: - Wire pieces

  var wireToolName: String {
    switch self {
    case .webSearch: "web_search"
    case .webFetch: "web_fetch"
    case .codeExecution: "code_execution"
    case .unrecognized(let activity): activity.toolName
    }
  }

  private var callPayload: JSONValue {
    switch self {
    case .webSearch(let search):
      .object(["query": .string(search.query)])
    case .webFetch(let fetch):
      .object(["url": .string(fetch.url.absoluteString)])
    case .codeExecution(let execution):
      .object(["code": .string(execution.code)])
    case .unrecognized(let activity):
      activity.callJSON.flatMap(JSONValue.parsed) ?? .object([:])
    }
  }

  private var resultWire: (type: String, payload: JSONValue)? {
    switch self {
    case .webSearch(let search):
      switch search.outcome {
      case .results(let hits):
        return ("web_search_tool_result", JSONValue.encoded(hits) ?? .array([]))
      case .failure(let errorCode):
        return (
          "web_search_tool_result",
          .object([
            "type": "web_search_tool_result_error",
            "error_code": .string(errorCode),
          ])
        )
      case nil:
        return nil
      }

    case .webFetch(let fetch):
      switch fetch.outcome {
      case .document(let document):
        var payload: [String: JSONValue] = ["type": "web_fetch_result"]
        if let url = document.url { payload["url"] = .string(url.absoluteString) }
        if let retrievedAt = document.retrievedAt {
          payload["retrieved_at"] = .string(retrievedAt)
        }
        if document.text != nil || document.title != nil {
          let mediaType = document.mediaType ?? "text/plain"
          var wireDocument: [String: JSONValue] = [
            "type": "document",
            "source": .object([
              "type": mediaType.hasPrefix("text") ? "text" : "base64",
              "media_type": .string(mediaType),
              "data": .string(document.text ?? ""),
            ]),
          ]
          if let title = document.title { wireDocument["title"] = .string(title) }
          payload["content"] = .object(wireDocument)
        }
        return ("web_fetch_tool_result", .object(payload))
      case .failure(let errorCode):
        return (
          "web_fetch_tool_result",
          .object([
            "type": "web_fetch_tool_result_error",
            "error_code": .string(errorCode),
          ])
        )
      case nil:
        return nil
      }

    case .codeExecution(let execution):
      switch execution.outcome {
      case .output(let output):
        var payload: [String: JSONValue] = ["type": "code_execution_result"]
        if let stdout = output.stdout { payload["stdout"] = .string(stdout) }
        if let stderr = output.stderr { payload["stderr"] = .string(stderr) }
        if let returnCode = output.returnCode {
          payload["return_code"] = .number(Double(returnCode))
        }
        if let encryptedStdout = output.encryptedStdout {
          payload["encrypted_stdout"] = .string(encryptedStdout)
        }
        return ("code_execution_tool_result", .object(payload))
      case .failure(let errorCode):
        return (
          "code_execution_tool_result",
          .object([
            "type": "code_execution_tool_result_error",
            "error_code": .string(errorCode),
          ])
        )
      case nil:
        return nil
      }

    case .unrecognized(let activity):
      guard let type = activity.resultType, let json = activity.resultJSON else { return nil }
      return (type, JSONValue.parsed(json) ?? .object([:]))
    }
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
  var encryptedStdout: String?

  enum CodingKeys: String, CodingKey {
    case stdout, stderr
    case returnCode = "return_code"
    case encryptedStdout = "encrypted_stdout"
  }
}

// MARK: - JSONValue bridging

extension JSONValue {
  /// Decodes the value into a `Decodable` type by round-tripping through
  /// `Data` — payload shapes are small, so clarity wins over speed.
  func decoded<Value: Decodable>() -> Value? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return try? JSONDecoder().decode(Value.self, from: data)
  }

  static func encoded(_ value: some Encodable) -> JSONValue? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }

  static func parsed(_ json: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
  }

  var jsonText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let data = try? encoder.encode(self) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}
