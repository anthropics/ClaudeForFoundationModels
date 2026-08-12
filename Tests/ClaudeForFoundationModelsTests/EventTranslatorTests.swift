// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
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

  @Test func `a server tool turn is recorded in order and surfaced as activity`() async throws {
    let blocks: [TurnBlock] = [
      .text(["Checking."]), .search(id: "srv_1", query: "weather"), .searchResult(id: "srv_1"),
      .text(["It is ", "sunny."]),
    ]
    let session = LanguageModelSession(model: StubbedClaudeModel(fixture: turn(blocks)))

    let response = try await session.respond(to: "weather?")

    // One segment per text block, and an empty one holding the search's place
    // between them, keyed to its payload by the API's tool-use id.
    let entry = try #require(responseEntries(in: session.transcript).first)
    #expect(
      entry.segments.map { segment -> String? in
        if case .text(let text) = segment { text.content } else { nil }
      } == ["Checking.", "", "It is sunny."]
    )
    #expect(entry.segments.dropFirst().first?.id == "srv_1")
    #expect(
      entry.segments.map { entry.claudeServerToolActivity(for: $0) } == [
        nil, searchActivity(id: "srv_1", query: "weather", answered: true), nil,
      ]
    )
    #expect(response.content == "Checking.It is sunny.")
    #expect(recordedBlocks(in: session.transcript) == blocks.map(\.wire))
    #expect(
      session.transcript.claudeServerToolActivity == [
        searchActivity(id: "srv_1", query: "weather", answered: true)
      ]
    )
  }

  @Test func `each block is recorded on the entry that presents it`() async throws {
    let tool = PingTool()
    let blocks: [TurnBlock] = [
      .thinking(["Let me ", "see."], signature: "c2ln"), .text(["One moment."]),
      .thinking(["Right."], signature: "bW9yZQ=="), .toolUse(id: "toolu_1", name: "ping"),
    ]
    let transport = MockTransport(responses: [
      (200, turn(blocks, stopReason: "tool_use")), (200, textTurn(deltas: ["Pong it is."])),
    ])
    let session = LanguageModelSession(
      model: StubbedClaudeModel(transport: transport),
      tools: [tool]
    )

    _ = try await session.respond(to: "ping?")

    // The turn's model entries, in the order the framework filed them.
    let entries = Array(
      session.transcript.drop { if case .reasoning = $0 { false } else { true } }.prefix(4)
    )
    guard entries.count == 4, case .reasoning(let first) = entries[0],
      case .response(let response) = entries[1], case .reasoning(let second) = entries[2],
      case .toolCalls(let calls) = entries[3]
    else {
      Issue.record("unexpected transcript shape: \(entries)")
      return
    }
    #expect(TurnRecord(metadata: first.metadata).blocks.map(\.json) == [blocks[0].wire])
    #expect(first.signature == Data(base64Encoded: "c2ln"))
    #expect(TurnRecord(metadata: response.metadata).blocks.map(\.json) == [blocks[1].wire])
    #expect(TurnRecord(metadata: second.metadata).blocks.map(\.json) == [blocks[2].wire])
    let call = try #require(calls.first)
    #expect(TurnRecord(metadata: call.metadata).blocks.map(\.json) == [blocks[3].wire])
    #expect(recordedBlocks(in: session.transcript).prefix(4).elementsEqual(blocks.map(\.wire)))
    // And the whole turn went back as sent when the tool output was returned.
    #expect(try replayedAssistantContent(in: transport) == [blocks.map(\.wire)])
  }

  @Test func `a recorded turn goes back to the API exactly as received`() async throws {
    let blocks: [TurnBlock] = [
      .search(id: "srv_1", query: "weather"), .searchResult(id: "srv_1"),
      .citedText("Sunny.", citation: "idx_1"),
    ]
    let transport = MockTransport(responses: [
      (200, turn(blocks)),
      (200, textTurn(deltas: ["You're welcome."])),
    ])
    let session = LanguageModelSession(model: StubbedClaudeModel(transport: transport))

    _ = try await session.respond(to: "weather?")
    _ = try await session.respond(to: "thanks")

    #expect(try replayedAssistantContent(in: transport) == [blocks.map(\.wire)])
  }

  @Test func `a search deferred behind a client tool call is answered in the next response`()
    async throws
  {
    let tool = PingTool()
    let firstTurn: [TurnBlock] = [
      .search(id: "srv_1", query: "q"), .toolUse(id: "toolu_1", name: "ping"),
    ]
    let secondTurn: [TurnBlock] = [.searchResult(id: "srv_1"), .text(["Both done."])]
    let transport = MockTransport(responses: [
      (200, turn(firstTurn, stopReason: "tool_use")),
      (200, turn(secondTurn)),
      (200, textTurn(deltas: ["Anytime."])),
    ])
    let session = LanguageModelSession(
      model: StubbedClaudeModel(transport: transport),
      tools: [tool]
    )

    let response = try await session.respond(to: "search and ping")

    #expect(response.content == "Both done.")
    #expect(tool.callCount == 1)
    #expect(
      session.transcript.claudeServerToolActivity == [
        searchActivity(id: "srv_1", query: "q", answered: true)
      ]
    )
    // The continuation carried the unanswered call back, as the API requires.
    #expect(try replayedAssistantContent(in: transport) == [firstTurn.map(\.wire)])

    _ = try await session.respond(to: "thanks")
    #expect(
      try replayedAssistantContent(in: transport) == [
        firstTurn.map(\.wire), secondTurn.map(\.wire),
      ]
    )
  }

  @Test func `a response that streams no text still records what it received`() async throws {
    // The deferred result arrives in a response that goes straight on to
    // another tool call: that response entry gets metadata and nothing else,
    // and must still exist to hold the result.
    let tool = PingTool()
    let transport = MockTransport(responses: [
      (
        200,
        turn(
          [.search(id: "srv_1", query: "q"), .toolUse(id: "toolu_1", name: "ping")],
          stopReason: "tool_use"
        )
      ),
      (
        200,
        turn(
          [.searchResult(id: "srv_1"), .toolUse(id: "toolu_2", name: "ping")],
          stopReason: "tool_use"
        )
      ),
      (200, turn([.text(["All done."])])),
      (200, textTurn(deltas: ["Anytime."])),
    ])
    let session = LanguageModelSession(
      model: StubbedClaudeModel(transport: transport),
      tools: [tool]
    )

    _ = try await session.respond(to: "search and ping twice")

    #expect(tool.callCount == 2)
    #expect(
      session.transcript.claudeServerToolActivity == [
        searchActivity(id: "srv_1", query: "q", answered: true)
      ]
    )
    _ = try await session.respond(to: "thanks")
    #expect(
      try replayedAssistantContent(in: transport).prefix(2)
        .elementsEqual([
          [TurnBlock.search(id: "srv_1", query: "q"), .toolUse(id: "toolu_1", name: "ping")]
            .map(\.wire),
          [TurnBlock.searchResult(id: "srv_1"), .toolUse(id: "toolu_2", name: "ping")].map(\.wire),
        ])
    )
  }

  @Test func `a paused turn is continued from where it stopped`() async throws {
    let paused: [TurnBlock] = [.search(id: "srv_1", query: "q"), .searchResult(id: "srv_1")]
    let transport = MockTransport(responses: [
      (200, turn(paused, stopReason: "pause_turn")),
      (200, turn([.text(["Done."])])),
    ])
    let session = LanguageModelSession(model: StubbedClaudeModel(transport: transport))

    let response = try await session.respond(to: "research this")

    #expect(response.content == "Done.")
    #expect(transport.requests.count == 2)
    // The continuation request re-sent the paused content as received.
    #expect(try replayedAssistantContent(in: transport) == [paused.map(\.wire)])
    // The turn's record and usage span both responses.
    #expect(recordedBlocks(in: session.transcript) == (paused + [.text(["Done."])]).map(\.wire))
    #expect(session.usage.input.totalTokenCount == 20)
    #expect(session.usage.output.totalTokenCount == 10)
  }

  @Test func `a continuation doesn't end in whitespace even when the paused content did`()
    async throws
  {
    // The paused content becomes the request's final assistant message,
    // where the API refuses trailing whitespace; the record keeps it as sent.
    let paused: [TurnBlock] = [
      .search(id: "srv_1", query: "q"), .searchResult(id: "srv_1"), .text(["So far: \n"]),
      .text(["\n\n"]),
    ]
    let transport = MockTransport(responses: [
      (200, turn(paused, stopReason: "pause_turn")),
      (200, turn([.text(["Done."])])),
    ])
    let session = LanguageModelSession(model: StubbedClaudeModel(transport: transport))

    _ = try await session.respond(to: "research this")

    #expect(
      try replayedAssistantContent(in: transport) == [
        paused.prefix(2).map(\.wire) + [["type": "text", "text": "So far:"]]
      ]
    )
    #expect(recordedBlocks(in: session.transcript).prefix(4).elementsEqual(paused.map(\.wire)))
  }

  @Test func `a pause that delivered nothing ends the turn`() async throws {
    let transport = MockTransport(responses: [
      (200, turn([.search(id: "srv_1", query: "q")], stopReason: "pause_turn")),
      (200, turn([], stopReason: "pause_turn")),
    ])
    let session = LanguageModelSession(model: StubbedClaudeModel(transport: transport))

    _ = try await session.respond(to: "loop")

    #expect(transport.requests.count == 2)
  }

  @Test func `a turn that ends mid-answer replays with the text that had streamed`() async throws {
    let completed: [TurnBlock] = [.search(id: "srv_1", query: "q"), .searchResult(id: "srv_1")]
    let whole = turn(completed + [.text(["Partial answer, "])])
    // The stream ends just before the text block's stop: its delta arrived
    // but the block never completed.
    let lastStop = try #require(
      whole.range(of: Data("event: content_block_stop".utf8), options: .backwards)
    )
    let transport = MockTransport(responses: [
      (200, whole[..<lastStop.lowerBound]), (200, textTurn(deltas: ["Carrying on."])),
    ])
    let session = LanguageModelSession(model: StubbedClaudeModel(transport: transport))

    let response = try await session.respond(to: "q?")

    // The completed blocks are recorded; the unfinished text is only in the
    // response's segments.
    #expect(response.content == "Partial answer, ")
    #expect(recordedBlocks(in: session.transcript) == completed.map(\.wire))

    _ = try await session.respond(to: "go on")

    #expect(
      try replayedAssistantContent(in: transport) == [
        completed.map(\.wire) + [["type": "text", "text": "Partial answer, "]]
      ]
    )
  }

  @Test func `activity is readable from the transcript while the answer is still streaming`()
    async throws
  {
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        fixture: turn([
          .search(id: "srv_1", query: "q"), .searchResult(id: "srv_1"),
          .text(["Here ", "is ", "the ", "answer."]),
        ])
      )
    )

    var activityAtFirstSnapshot: [ClaudeServerToolActivity]?
    for try await _ in session.streamResponse(to: "q?") where activityAtFirstSnapshot == nil {
      activityAtFirstSnapshot = session.transcript.claudeServerToolActivity
    }

    // The search is on the transcript from the first snapshot, not only once
    // the turn is over.
    #expect(activityAtFirstSnapshot?.map(\.id) == ["srv_1"])
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
