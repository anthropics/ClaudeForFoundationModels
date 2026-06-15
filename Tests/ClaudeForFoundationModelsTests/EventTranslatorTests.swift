// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import Testing

@testable import ClaudeForFoundationModels

@Suite struct EventTranslatorTests {
  private func translated(_ jsonLines: [String]) async throws -> [RecordedEvent] {
    try await recordedEvents { channel in
      let translator = EventTranslator(responseEntryID: "r", toolCallsEntryID: "t")
      try await translator.translate(stream(jsonLines), into: channel)
    }
  }

  @Test func `text deltas become appendText events`() async throws {
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
    ])
    // A zero count would suppress partial-snapshot delivery; see
    // `EventTranslator.deltaTokenCount`.
    #expect(
      events == [
        .responseText(entryID: "r", text: "Hello", tokenCount: 1),
        .responseText(entryID: "r", text: ", world", tokenCount: 1),
      ]
    )
  }

  @Test func `thinking deltas become reasoning appendText events`() async throws {
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think"}}"#,
    ])
    // Reasoning is a top-level entry, not nested in the response. The entry id
    // is minted per thinking block, so match structurally rather than by id.
    #expect(events.count == 1)
    guard case .reasoningText(let entryID, "Let me think", let tokenCount) = events[0] else {
      Issue.record("expected reasoning appendText, got \(events[0])")
      return
    }
    #expect(entryID != nil)
    #expect(tokenCount > 0)
  }

  @Test func `tool call streams to a separate tool-calls entry`() async throws {
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"getWeather","input":{}}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"SF\"}"}}"#,
    ])
    #expect(
      events == [
        .toolCallArguments(
          entryID: "t",
          id: "toolu_1",
          name: "getWeather",
          arguments: "",
          tokenCount: 0
        ),
        .toolCallArguments(
          entryID: "t",
          id: "toolu_1",
          name: "getWeather",
          arguments: #"{"city":"#,
          tokenCount: 1
        ),
        .toolCallArguments(
          entryID: "t",
          id: "toolu_1",
          name: "getWeather",
          arguments: #""SF"}"#,
          tokenCount: 1
        ),
      ]
    )
  }

  @Test func `structured output streams as plain text deltas`() async throws {
    // With output_config.format the response is constrained-decoded JSON
    // streaming as ordinary text deltas — no synthetic tool, no special routing.
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\"title\":"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\"Trip\"}"}}"#,
    ])
    #expect(
      events == [
        .responseText(entryID: "r", text: #"{"title":"#, tokenCount: 1),
        .responseText(entryID: "r", text: #""Trip"}"#, tokenCount: 1),
      ]
    )
  }

  @Test func `usage is cumulative and wholesale`() async throws {
    let events = try await translated([
      #"{"type":"message_start","message":{"id":"msg_1","model":"x","role":"assistant","content":[],"usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":80,"cache_creation_input_tokens":15}}}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
    ])
    // The input total is the whole prompt — uncached + cache reads + cache
    // writes — with reads as the cached subset.
    #expect(
      events == [
        .responseUsage(
          entryID: "r",
          inputTotal: 195,
          inputCached: 80,
          outputTotal: 42,
          outputReasoning: 0
        )
      ]
    )
  }

  @Test func `error event throws the typed APIError`() async throws {
    await #expect(throws: APIError.self) {
      try await translated([
        #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#
      ])
    }
  }

  @Test func `signature delta becomes reasoning updateSignature`() async throws {
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"AAEC"}}"#,
    ])
    #expect(events.count == 2)
    guard case .reasoningText(let textEntryID, "hmm", _) = events[0] else {
      Issue.record("expected reasoning appendText, got \(events[0])")
      return
    }
    guard case .reasoningSignature(let sigEntryID, let data) = events[1] else {
      Issue.record("expected reasoning updateSignature, got \(events[1])")
      return
    }
    #expect(data == Data(base64Encoded: "AAEC"))
    // Text and signature anchor to the same per-block reasoning entry.
    #expect(textEntryID == sigEntryID)
    #expect(textEntryID != nil)
  }

  @Test func `server tool input arriving whole in the start block is parsed`() async throws {
    // The agentic search flow delivers the call input in content_block_start
    // with no input_json_delta events. The segment is surfaced at block start
    // and re-emitted (unchanged) at block stop.
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_2","name":"web_search","input":{"query":"weather"}}}"#,
      #"{"type":"content_block_stop","index":0}"#,
    ])
    #expect(events.count == 2)
    for event in events {
      guard case .responseCustomSegment("r", "srv_2", .webSearch(let call)) = event else {
        Issue.record("expected webSearch segment, got \(event)")
        return
      }
      #expect(call.query == "weather")
      #expect(call.outcome == nil)
    }
  }

  @Test func `redacted thinking becomes a marked signature-only reasoning entry`() async throws {
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"AAEC"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
    ])
    #expect(events.count == 2)
    guard case .reasoningMetadata(let metadataEntryID, let keys) = events[0] else {
      Issue.record("expected reasoning updateMetadata, got \(events[0])")
      return
    }
    #expect(keys == [redactedThinkingMetadataKey])
    guard case .reasoningSignature(let entryID, let data) = events[1] else {
      Issue.record("expected reasoning updateSignature, got \(events[1])")
      return
    }
    #expect(data == Data(base64Encoded: "AAEC"))
    #expect(entryID != nil)
    #expect(entryID == metadataEntryID)
  }

  @Test func `unknown events and deltas are ignored, not thrown`() async throws {
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"some_future_delta","stuff":1}}"#,
      #"{"type":"some_future_event","stuff":1}"#,
    ])
    #expect(events == [.responseText(entryID: "r", text: "Hi", tokenCount: 1)])
  }

  @Test func `server tool use and result become custom segments`() async throws {
    let events = try await translated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{}}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"weather\"}"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[{"type":"web_search_result","url":"https://weather.gov","title":"NWS","page_age":"June 7, 2026"}]}}"#,
    ])
    #expect(events.count == 2)
    // The call emits a segment immediately (results pending)…
    guard case .responseCustomSegment("r", "srv_1", .webSearch(let call)) = events[0] else {
      Issue.record("expected webSearch segment, got \(events[0])")
      return
    }
    #expect(call.query == "weather")
    #expect(call.outcome == nil)
    // …and the result updates the same segment id with the hits attached.
    guard case .responseCustomSegment("r", "srv_1", .webSearch(let completed)) = events[1]
    else {
      Issue.record("expected completed webSearch segment, got \(events[1])")
      return
    }
    #expect(completed.query == "weather")
    guard case .results(let hits)? = completed.outcome else {
      Issue.record("expected results outcome, got \(String(describing: completed.outcome))")
      return
    }
    #expect(hits.count == 1)
    #expect(hits[0].url == URL(string: "https://weather.gov"))
    #expect(hits[0].title == "NWS")
    #expect(hits[0].pageAge == "June 7, 2026")
  }
}

// MARK: - Test helpers

private func stream(_ jsonLines: [String]) -> AsyncThrowingStream<StreamEvent, Error> {
  AsyncThrowingStream { continuation in
    for line in jsonLines {
      do {
        let event = try JSONDecoder().decode(StreamEvent.self, from: Data(line.utf8))
        if case .error(let e) = event {
          continuation.finish(throwing: e)
          return
        }
        continuation.yield(event)
      } catch {
        continuation.finish(throwing: error)
        return
      }
    }
    continuation.finish()
  }
}
