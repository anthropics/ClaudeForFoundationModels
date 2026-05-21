// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeAPI

/// Pure encode/decode coverage for the wire model types — no network.
@Suite struct ModelCodingTests {

  // MARK: - JSONValue

  @Test func `JSONValue round-trips every case`() throws {
    let value: JSONValue = .object([
      "n": .null,
      "b": .bool(true),
      "num": .number(3.5),
      "s": .string("hi"),
      "arr": .array([.number(1), .string("two"), .bool(false)]),
      "nested": .object(["k": .array([.null])]),
    ])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
  }

  @Test func `JSONValue literals build the expected cases`() {
    #expect(JSONValue(nilLiteral: ()) == .null)
    let dict: JSONValue = ["a": 1, "ok": true, "name": "x"]
    #expect(dict == .object(["a": .number(1), "ok": .bool(true), "name": .string("x")]))
    let arr: JSONValue = [1, 2, 3]
    #expect(arr == .array([.number(1), .number(2), .number(3)]))
  }

  // MARK: - ContentBlock

  @Test func `ContentBlock image round-trips as base64`() throws {
    let block = ContentBlock.image(
      ImageSource(mediaType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
    )
    let data = try JSONEncoder().encode(block)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let source = try #require(json["source"] as? [String: Any])
    #expect(source["type"] as? String == "base64")
    #expect(source["media_type"] as? String == "image/jpeg")
    #expect(try JSONDecoder().decode(ContentBlock.self, from: data) == block)
  }

  @Test func `ImageSource rejects invalid base64`() {
    let payload = #"{"type":"base64","media_type":"image/png","data":"not base64!!"}"#
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ImageSource.self, from: Data(payload.utf8))
    }
  }

  @Test func `tool_result omits is_error when false, emits it when true`() throws {
    let ok = try #require(
      try JSONSerialization.jsonObject(
        with: JSONEncoder()
          .encode(ContentBlock.toolResult(toolUseID: "t", content: [.text("done")]))
      )
        as? [String: Any]
    )
    #expect(ok["is_error"] == nil)

    let bad = try #require(
      try JSONSerialization.jsonObject(
        with: JSONEncoder()
          .encode(
            ContentBlock.toolResult(toolUseID: "t", content: [.text("boom")], isError: true)
          )
      )
        as? [String: Any]
    )
    #expect(bad["is_error"] as? Bool == true)
  }

  @Test func `tool_result content encodes lone text as a string and mixed blocks as an array`()
    throws
  {
    let lone = try #require(
      try JSONSerialization.jsonObject(
        with: JSONEncoder()
          .encode(ContentBlock.toolResult(toolUseID: "t", content: [.text("done")]))
      ) as? [String: Any]
    )
    #expect(lone["content"] as? String == "done")

    let mixed = try #require(
      try JSONSerialization.jsonObject(
        with: JSONEncoder()
          .encode(
            ContentBlock.toolResult(
              toolUseID: "t",
              content: [
                .text("shot"), .image(ImageSource(mediaType: "image/jpeg", data: Data([1]))),
              ]
            )
          )
      ) as? [String: Any]
    )
    let blocks = try #require(mixed["content"] as? [[String: Any]])
    #expect(blocks.count == 2)
    #expect(blocks[0]["type"] as? String == "text")
    #expect(blocks[1]["type"] as? String == "image")
  }

  @Test func `thinking decodes with and without a signature`() throws {
    let signed = try JSONDecoder()
      .decode(
        ContentBlock.self,
        from: Data(#"{"type":"thinking","thinking":"hmm","signature":"sig"}"#.utf8)
      )
    #expect(signed == .thinking("hmm", signature: "sig"))

    let unsigned = try JSONDecoder()
      .decode(
        ContentBlock.self,
        from: Data(#"{"type":"thinking","thinking":"hmm"}"#.utf8)
      )
    #expect(unsigned == .thinking("hmm", signature: nil))
  }

  @Test func `redacted_thinking decodes base64 payload to bytes`() throws {
    let block = try JSONDecoder()
      .decode(
        ContentBlock.self,
        from: Data(#"{"type":"redacted_thinking","data":"AAEC"}"#.utf8)
      )
    #expect(block == .redactedThinking(Data([0x00, 0x01, 0x02])))
  }

  @Test func `server_tool_use decodes`() throws {
    let block = try JSONDecoder()
      .decode(
        ContentBlock.self,
        from: Data(
          #"{"type":"server_tool_use","id":"st_1","name":"web_search","input":{"q":"x"}}"#.utf8
        )
      )
    #expect(
      block == .serverToolUse(id: "st_1", name: "web_search", input: .object(["q": .string("x")]))
    )
  }

  @Test func `any _tool_result suffix decodes as a server tool result`() throws {
    let block = try JSONDecoder()
      .decode(
        ContentBlock.self,
        from: Data(
          #"{"type":"web_search_tool_result","tool_use_id":"st_1","content":[{"title":"T"}]}"#.utf8
        )
      )
    guard case .serverToolResult(let id, let type, let content) = block else {
      Issue.record("expected serverToolResult, got \(block)")
      return
    }
    #expect(id == "st_1")
    #expect(type == "web_search_tool_result")
    #expect(content == .array([.object(["title": .string("T")])]))
  }

  @Test func `unrecognized content block surfaces as unknown`() throws {
    let block = try JSONDecoder()
      .decode(
        ContentBlock.self,
        from: Data(#"{"type":"future_block","data":123}"#.utf8)
      )
    #expect(block == .unknown(type: "future_block"))
  }

  @Test func `unknown stop_reason decodes leniently instead of killing the stream`() throws {
    let payload =
      #"{"type":"message_delta","delta":{"stop_reason":"some_future_reason"},"usage":{"output_tokens":1}}"#
    let event = try JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8))
    guard case .messageDelta(let stopReason, _) = event else {
      Issue.record("expected messageDelta, got \(event)")
      return
    }
    #expect(stopReason == .unknown)

    let pause =
      #"{"type":"message_delta","delta":{"stop_reason":"pause_turn"},"usage":{"output_tokens":1}}"#
    guard
      case .messageDelta(.pauseTurn?, _) = try JSONDecoder()
        .decode(StreamEvent.self, from: Data(pause.utf8))
    else {
      Issue.record("expected pause_turn stop reason")
      return
    }
  }

  @Test func `unknown error type still decodes as a typed APIError`() throws {
    let payload =
      #"{"type":"error","error":{"type":"billing_error","message":"insufficient funds"}}"#
    let event = try JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8))
    guard case .error(let apiError) = event else {
      Issue.record("expected error event, got \(event)")
      return
    }
    #expect(apiError.kind == .other)
    #expect(apiError.message == "insufficient funds")
  }

  // MARK: - ToolDefinition

  @Test func `server tool definitions round-trip their flat config`() throws {
    let tool = ToolDefinition(
      serverType: "web_search_20260209",
      name: "web_search",
      config: [
        "allowed_domains": .array([.string("example.com")]),
        "max_uses": .number(3),
      ]
    )
    let decoded = try JSONDecoder().decode(ToolDefinition.self, from: JSONEncoder().encode(tool))
    #expect(decoded.serverType == "web_search_20260209")
    #expect(decoded.name == "web_search")
    #expect(decoded.inputSchema == nil)
    #expect(decoded.config["allowed_domains"] == .array([.string("example.com")]))
    #expect(decoded.config["max_uses"] == .number(3))
  }

  // MARK: - StreamEvent

  @Test func `message_start decodes the seed response`() throws {
    let payload = #"""
      {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-4-7","role":"assistant","content":[],"usage":{"input_tokens":7,"output_tokens":0}}}
      """#
    let event = try JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8))
    guard case .messageStart(let resp) = event else {
      Issue.record("expected messageStart, got \(event)")
      return
    }
    #expect(resp.id == "msg_1")
    #expect(resp.usage.inputTokens == 7)
  }

  @Test func `content_block_start decodes a tool_use block`() throws {
    let payload = #"""
      {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"get_weather","input":{}}}
      """#
    let event = try JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8))
    guard case .contentBlockStart(let index, .toolUse(let id, let name, _)) = event else {
      Issue.record("expected contentBlockStart/toolUse, got \(event)")
      return
    }
    #expect(index == 2)
    #expect(id == "toolu_9")
    #expect(name == "get_weather")
  }

  @Test func `thinking, signature, and input_json deltas decode`() throws {
    // StreamEvent / Delta aren't Equatable, so match structurally.
    func delta(_ json: String) throws -> StreamEvent.Delta {
      let e = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
      guard case .contentBlockDelta(_, let d) = e else {
        Issue.record("expected contentBlockDelta, got \(e)")
        return .unknown(type: "n/a")
      }
      return d
    }
    guard
      case .thinking(let t) = try delta(
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"t"}}"#
      )
    else {
      Issue.record("expected thinking")
      return
    }
    #expect(t == "t")

    guard
      case .signature(let s) = try delta(
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#
      )
    else {
      Issue.record("expected signature")
      return
    }
    #expect(s == "sig")

    guard
      case .inputJSON(let j) = try delta(
        #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":1}"}}"#
      )
    else {
      Issue.record("expected inputJSON")
      return
    }
    #expect(j == #"{"a":1}"#)
  }

  @Test func `unknown delta and event types surface, not throw`() throws {
    let unknownDelta = try JSONDecoder()
      .decode(
        StreamEvent.self,
        from: Data(
          #"{"type":"content_block_delta","index":0,"delta":{"type":"audio_delta","x":1}}"#.utf8
        )
      )
    guard case .contentBlockDelta(_, .unknown(let dt)) = unknownDelta else {
      Issue.record("expected unknown delta, got \(unknownDelta)")
      return
    }
    #expect(dt == "audio_delta")

    let unknownEvent = try JSONDecoder()
      .decode(
        StreamEvent.self,
        from: Data(#"{"type":"thread_event"}"#.utf8)
      )
    #expect(
      {
        if case .unknown(let t) = unknownEvent { return t == "thread_event" } else { return false }
      }()
    )
  }

  @Test func `message_stop and ping decode`() throws {
    let stop = try JSONDecoder()
      .decode(StreamEvent.self, from: Data(#"{"type":"message_stop"}"#.utf8))
    #expect({ if case .messageStop = stop { return true } else { return false } }())
    let ping = try JSONDecoder().decode(StreamEvent.self, from: Data(#"{"type":"ping"}"#.utf8))
    #expect({ if case .ping = ping { return true } else { return false } }())
  }

  // MARK: - MessagesResponse

  @Test func `MessagesResponse decodes content, stop reason, and cache usage`() throws {
    let payload = #"""
      {"id":"msg_2","model":"claude-sonnet-4-6","role":"assistant","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":80}}
      """#
    let resp = try JSONDecoder().decode(MessagesResponse.self, from: Data(payload.utf8))
    #expect(resp.id == "msg_2")
    #expect(resp.role == .assistant)
    #expect(resp.content == [.text("hello")])
    #expect(resp.stopReason == .endTurn)
    #expect(resp.usage.inputTokens == 100)
    #expect(resp.usage.cacheReadInputTokens == 80)
    #expect(resp.usage.cacheCreationInputTokens == nil)
  }

  // MARK: - APIError

  @Test func `APIError description includes the request id when present`() {
    let withID = APIError(kind: .rateLimit, message: "slow down", requestID: "req_9")
    #expect(withID.errorDescription == "rate_limit_error: slow down (request_id: req_9)")
    let withoutID = APIError(kind: .overloaded, message: "busy")
    #expect(withoutID.errorDescription == "overloaded_error: busy")
  }
}
