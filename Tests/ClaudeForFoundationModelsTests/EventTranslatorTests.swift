// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import ClaudeForFoundationModels

@Suite struct EventTranslatorTests {
  @Test func `text deltas stream as multiple cumulative snapshots`() async throws {
    let session = LanguageModelSession(
      model: StubbedClaudeModel(fixture: textTurn(deltas: ["Hello", ", world"]))
    )

    var snapshots: [String] = []
    for try await snapshot in session.streamResponse(to: "hi") {
      snapshots.append(snapshot.content)
    }

    // Snapshot pacing and intermediate contents are the framework's policy;
    // pin only that snapshots are cumulative and converge on the full text.
    #expect(snapshots.count >= 2)
    #expect(snapshots.last == "Hello, world")
    #expect(snapshots.allSatisfy { "Hello, world".hasPrefix($0) })
  }

  @Test func `delta token counts are nonzero so partial snapshots deliver`() {
    // The framework paces snapshot delivery by reported token counts, and a
    // zero count defers everything to one final snapshot (issue #2). Per-event
    // counts aren't observable through the session, so pin the constant.
    #expect(EventTranslator.deltaTokenCount > 0)
  }

  @Test func `a tool call round-trips through the session`() async throws {
    let tool = WeatherTool()
    let transport = MockTransport(responses: [
      (
        200,
        toolCallTurn(id: "toolu_1", name: "getWeather", argumentDeltas: [#"{"city":"#, #""SF"}"#])
      ),
      (200, textTurn(deltas: ["Done!"])),
    ])
    let session = LanguageModelSession(
      model: StubbedClaudeModel(transport: transport),
      tools: [tool]
    )

    let response = try await session.respond(to: "weather in SF?")

    #expect(tool.calledCities == ["SF"])
    #expect(response.content == "Done!")
    #expect(transport.requests.count == 2)
    // The follow-up request replays the call's result to the API.
    let followupBody = try #require(transport.requests.last?.httpBody)
    let followup = String(decoding: followupBody, as: UTF8.self)
    #expect(followup.contains("tool_result"))
    #expect(followup.contains("Sunny"))
  }

  @Test func `a tool call with no streamed arguments still invokes the tool`() async throws {
    let tool = PingTool()
    let transport = MockTransport(responses: [
      (200, toolCallTurn(id: "toolu_2", name: "ping", argumentDeltas: [])),
      (200, textTurn(deltas: ["Done!"])),
    ])
    let session = LanguageModelSession(
      model: StubbedClaudeModel(transport: transport),
      tools: [tool]
    )

    let response = try await session.respond(to: "ping it")

    #expect(tool.callCount == 1)
    #expect(response.content == "Done!")
  }

  @Test func `structured output decodes from streamed text deltas`() async throws {
    // With output_config.format the response is constrained-decoded JSON
    // streaming as ordinary text deltas — no synthetic tool, no special routing.
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: MockTransport(body: textTurn(deltas: [#"{"title":"#, #""Trip"}"#])),
        capabilities: [.toolCalling, .reasoning, .guidedGeneration]
      )
    )

    let response = try await session.respond(to: "plan", generating: StubItinerary.self)

    #expect(response.content == StubItinerary(title: "Trip"))
  }

  @Test func `usage totals are cumulative and wholesale`() async throws {
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        fixture: textTurn(
          deltas: ["Hi"],
          inputTokens: 100,
          cacheReadTokens: 80,
          cacheCreationTokens: 15,
          outputTokens: 42
        )
      )
    )

    _ = try await session.respond(to: "hi")

    // The input total is the whole prompt — uncached + cache reads + cache
    // writes — with reads as the cached subset.
    #expect(session.usage.input.totalTokenCount == 195)
    #expect(session.usage.input.cachedTokenCount == 80)
    #expect(session.usage.output.totalTokenCount == 42)
    #expect(session.usage.output.reasoningTokenCount == 0)
  }

  @Test func `an SSE error event surfaces as the mapped typed error`() async throws {
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        fixture: sseBody([
          [
            "event: error",
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#,
          ]
        ])
      )
    )

    let error = try await #require(throws: LanguageModelError.self) {
      _ = try await session.respond(to: "hi")
    }
    guard case .rateLimited = error else {
      Issue.record("expected rateLimited, got \(error)")
      return
    }
  }

  @Test func `server tool input arriving whole in the start block is parsed`() async throws {
    // The agentic search flow delivers the call input in content_block_start
    // with no input_json_delta events.
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        fixture: sseBody([
          [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1}}}"#,
          ],
          [
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_2","name":"web_search","input":{"query":"weather"}}}"#,
          ],
          ["event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#],
          [
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
          ],
          [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Searching."}}"#,
          ],
          ["event: content_block_stop", #"data: {"type":"content_block_stop","index":1}"#],
          [
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
          ],
          ["event: message_stop", #"data: {"type":"message_stop"}"#],
        ])
      )
    )

    _ = try await session.respond(to: "weather?")

    let segments = serverToolSegments(in: session.transcript)
    #expect(segments.count == 1)
    let segment = try #require(segments.first)
    #expect(segment.id == "srv_2")
    guard case .webSearch(let search) = segment.content else {
      Issue.record("expected webSearch, got \(segment.content)")
      return
    }
    #expect(search.query == "weather")
    #expect(search.outcome == nil)
  }

  @Test func `server tool use and result merge into one transcript segment`() async throws {
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        fixture: sseBody([
          [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1}}}"#,
          ],
          [
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{}}}"#,
          ],
          [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
          ],
          [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"weather\"}"}}"#,
          ],
          ["event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#],
          [
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[{"type":"web_search_result","url":"https://weather.gov","title":"NWS","page_age":"June 7, 2026"}]}}"#,
          ],
          ["event: content_block_stop", #"data: {"type":"content_block_stop","index":1}"#],
          [
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
          ],
          [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"It is sunny."}}"#,
          ],
          ["event: content_block_stop", #"data: {"type":"content_block_stop","index":2}"#],
          [
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
          ],
          ["event: message_stop", #"data: {"type":"message_stop"}"#],
        ])
      )
    )

    let response = try await session.respond(to: "weather?")
    #expect(response.content.contains("It is sunny."))

    // Call and result share a segment id, so the result's update replaces the
    // pending call segment instead of adding a second one.
    let segments = serverToolSegments(in: session.transcript)
    #expect(segments.count == 1)
    let segment = try #require(segments.first)
    #expect(segment.id == "srv_1")
    guard case .webSearch(let search) = segment.content else {
      Issue.record("expected webSearch, got \(segment.content)")
      return
    }
    #expect(search.query == "weather")
    guard case .results(let hits)? = search.outcome else {
      Issue.record("expected results outcome, got \(String(describing: search.outcome))")
      return
    }
    #expect(hits.count == 1)
    #expect(hits[0].url == URL(string: "https://weather.gov"))
    #expect(hits[0].title == "NWS")
    #expect(hits[0].pageAge == "June 7, 2026")
  }

  @Test func `unknown events and deltas are ignored, not thrown`() async throws {
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        fixture: sseBody([
          [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1}}}"#,
          ],
          [
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
          ],
          [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
          ],
          [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"some_future_delta","stuff":1}}"#,
          ],
          ["event: some_future_event", #"data: {"type":"some_future_event","stuff":1}"#],
          ["event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#],
          [
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
          ],
          ["event: message_stop", #"data: {"type":"message_stop"}"#],
        ])
      )
    )

    let response = try await session.respond(to: "hi")
    #expect(response.content == "Hi")
  }
}

// MARK: - Fixtures

/// An assistant turn that calls a client tool, streaming its arguments.
private func toolCallTurn(id: String, name: String, argumentDeltas: [String]) -> Data {
  var frames: [[String]] = [
    [
      "event: message_start",
      #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1}}}"#,
    ],
    [
      "event: content_block_start",
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#,
    ],
  ]
  for delta in argumentDeltas {
    let escaped = String(decoding: try! JSONEncoder().encode(delta), as: UTF8.self)
    frames.append([
      "event: content_block_delta",
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\#(escaped)}}"#,
    ])
  }
  frames += [
    ["event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#],
    [
      "event: message_delta",
      #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}"#,
    ],
    ["event: message_stop", #"data: {"type":"message_stop"}"#],
  ]
  return sseBody(frames)
}

@Generable
private struct StubItinerary: Equatable {
  let title: String
}

private final class PingTool: Tool {
  let name = "ping"
  let description = "Pings."

  @Generable
  struct Arguments {}

  private let count = Mutex<Int>(0)
  var callCount: Int { count.withLock { $0 } }

  func call(arguments: Arguments) async throws -> String {
    count.withLock { $0 += 1 }
    return "Pong"
  }
}

private final class WeatherTool: Tool {
  let name = "getWeather"
  let description = "Gets the weather for a city."

  @Generable
  struct Arguments {
    let city: String
  }

  private let cities = Mutex<[String]>([])
  var calledCities: [String] { cities.withLock { $0 } }

  func call(arguments: Arguments) async throws -> String {
    cities.withLock { $0.append(arguments.city) }
    return "Sunny"
  }
}
