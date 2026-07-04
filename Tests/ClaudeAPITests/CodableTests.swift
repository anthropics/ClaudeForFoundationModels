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
