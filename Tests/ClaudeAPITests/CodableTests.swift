// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeAPI

@Suite struct CodableTests {
  @Test func `encodes a full MessagesRequest`() throws {
    let req = MessagesRequest(
      model: "claude-opus-4-7",
      maxTokens: 1024,
      system: "Be terse.",
      messages: [.user("hi")],
      tools: [
        .init(
          name: "echo",
          description: "Echoes input",
          inputSchema: ["type": "object", "properties": ["x": ["type": "string"]]]
        )
      ],
      thinking: .adaptive(display: .summarized),
      cacheControl: .init(ttl: .oneHour),
      stream: true
    )
    let data = try JSONEncoder().encode(req)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["model"] as? String == "claude-opus-4-7")
    #expect(json["max_tokens"] as? Int == 1024)
    #expect((json["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    #expect((json["thinking"] as? [String: Any])?["display"] as? String == "summarized")
    #expect((json["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
    #expect((json["tools"] as? [[String: Any]])?.first?["input_schema"] != nil)
  }

  // A fallback entry's field replaces the request's whole field for that
  // model, and the API reads `null` as "keep the request's value". So an entry
  // writes only the fields it overrides, and each one is complete.
  @Test func `fallback entries write only the fields they override`() throws {
    let entries: [Fallback] = [
      .init(model: "claude-a"),
      .init(
        model: "claude-b",
        thinking: .adaptive(display: .summarized),
        outputConfig: .init(effort: .low)
      ),
      .init(model: "claude-c", thinking: .disabled, outputConfig: .init()),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(Fallbacks.models(entries))
    #expect(
      String(decoding: data, as: UTF8.self)
        == #"[{"model":"claude-a"},"#
        + #"{"model":"claude-b","output_config":{"effort":"low"},"#
        + #""thinking":{"display":"summarized","type":"adaptive"}},"#
        + #"{"model":"claude-c","output_config":{},"thinking":{"type":"disabled"}}]"#
    )
    #expect(try JSONDecoder().decode(Fallbacks.self, from: data) == .models(entries))
  }

  @Test func `each form of fallbacks names the beta it needs`() {
    #expect(Fallbacks.models([.init(model: "claude-a")]).requiredBeta == Fallbacks.betaHeader)
    #expect(Fallbacks.serverDefault.requiredBeta == Fallbacks.defaultRoutingBetaHeader)
    #expect(Fallbacks.betaHeader == "server-side-fallback-2026-06-01")
    #expect(Fallbacks.defaultRoutingBetaHeader == "server-side-fallback-2026-07-01")
  }

  @Test func `a request sends fallbacks only when it has some`() throws {
    let withDefault = MessagesRequest(
      model: "claude-a",
      messages: [.user("hi")],
      fallbacks: .serverDefault
    )
    let json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(withDefault)) as? [String: Any]
    )
    #expect(json["fallbacks"] as? String == "default")

    let plain = MessagesRequest(model: "claude-a", messages: [.user("hi")])
    let plainJSON = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
    )
    #expect(plainJSON["fallbacks"] == nil)
  }

  @Test func `decodes a text delta event`() throws {
    let payload =
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
    let event = try JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8))
    guard case .contentBlockDelta(let i, .text(let t)) = event else {
      Issue.record("wrong case")
      return
    }
    #expect(i == 0)
    #expect(t == "Hi")
  }

  @Test func `decodes a message delta event with usage`() throws {
    let payload =
      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#
    let event = try JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8))
    guard case .messageDelta(let reason, let usage) = event else {
      Issue.record("wrong case")
      return
    }
    #expect(reason == .endTurn)
    #expect(usage.outputTokens == 12)
    #expect(usage.inputTokens == nil)
  }

  @Test func `decodes the API error envelope`() throws {
    let body =
      #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"},"request_id":"req_123"}"#
    let env = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(body.utf8))
    #expect(env.error.kind == .rateLimit)
    #expect(env.requestID == "req_123")
  }

  @Test func `decodes a tool_use content block`() throws {
    let payload = #"{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"SF"}}"#
    let block = try JSONDecoder().decode(ContentBlock.self, from: Data(payload.utf8))
    guard case .toolUse(let id, let name, let input) = block else {
      Issue.record("wrong case")
      return
    }
    #expect(id == "toolu_1")
    #expect(name == "get_weather")
    #expect(input == .object(["city": .string("SF")]))
  }
}
