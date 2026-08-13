// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

@Suite struct TurnRecordTests {
  @Test func `blocks are read by the fields the bridge acts on`() {
    #expect(TurnRecord.Kind(["type": "text", "text": "Hi", "citations": []]) == .text("Hi"))
    #expect(
      TurnRecord.Kind(["type": "thinking", "thinking": "hm", "signature": "c2ln"]) == .thinking
    )
    #expect(TurnRecord.Kind(["type": "redacted_thinking", "data": "AAAA"]) == .redactedThinking)
    #expect(
      TurnRecord.Kind(["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]])
        == .toolUse(id: "toolu_1", name: "ping")
    )
    #expect(
      TurnRecord.Kind(serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"]))
        == .serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"])
    )
    // Tool families this package doesn't know get the same treatment.
    #expect(
      TurnRecord.Kind(["type": "mcp_tool_use", "id": "m_1", "name": "x", "input": [:]])
        == .serverToolUse(id: "m_1", name: "x", input: [:])
    )
    #expect(
      TurnRecord.Kind(["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": []])
        == .serverToolResult(type: "web_search_tool_result", toolUseID: "srv_1", content: [])
    )
    #expect(TurnRecord.Kind(["type": "future_block", "n": 1]) == .other)
    // A known type missing the fields it's read by is echoed, not acted on.
    #expect(TurnRecord.Kind(["type": "tool_use", "name": "ping"]) == .other)
  }

  @Test func `every JSON shape comes back out of entry metadata as it went in`() {
    let blocks: [JSONValue] = [
      [
        "type": "web_search_tool_result",
        "tool_use_id": "srv_1",
        "content": [
          [
            "url": "https://example.com/a?b=1", "page_age": nil, "rank": 1, "score": 0.5,
            "fresh": true, "tags": ["a", "b"], "nested": ["deep": ["er": [:]]],
          ]
        ],
      ],
      ["type": "text", "text": "Ünïcödé \"quoted\" \n newline"],
    ]
    let response = Transcript.Response(metadata: record(blocks, from: 3).metadata, segments: [])
    let restored = TurnRecord(metadata: response.metadata)
    #expect(restored.blocks.map(\.json) == blocks)
    #expect(restored.blocks.map(\.position) == [3, 4])
    #expect(restored.turn == "turn-1")
  }

  @Test func `records survive persisting the transcript`() throws {
    let thinking: JSONValue = ["type": "redacted_thinking", "data": "3q2+7w=="]
    let call: JSONValue = ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": ["n": 1]]
    let blocks: [JSONValue] = [
      serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"]),
      [
        "type": "web_search_tool_result", "tool_use_id": "srv_1",
        "content": [["type": "web_search_result", "encrypted_content": "opaque", "page_age": nil]],
      ],
      ["type": "text", "text": "Done.", "citations": [["encrypted_index": "idx", "count": 2]]],
    ]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "q?"))])),
      recordedReasoning(thinking, at: 0),
      recordedResponse(blocks, from: 1),
      try recordedToolCall(call, at: 4),
    ])

    let restored = try JSONDecoder()
      .decode(Transcript.self, from: try JSONEncoder().encode(transcript))

    #expect(recordedBlocks(in: restored) == [thinking] + blocks + [call])
  }

  @Test func `the stored form is stable text`() {
    // Equal records must store equal text, so a transcript's metadata (and
    // its persisted form) is the same however the blocks' fields were ordered.
    let a = record([["type": "text", "text": "x", "citations": [["b": 1, "a": 2]]]]).metadata
    let b = record([["citations": [["a": 2, "b": 1]], "text": "x", "type": "text"]]).metadata
    #expect(
      (a[TurnRecord.metadataKey] as? String) == (b[TurnRecord.metadataKey] as? String)
    )
    #expect(a[TurnRecord.metadataKey] is String)
  }

  @Test func `entries without a usable record read as empty`() {
    #expect(TurnRecord(metadata: Transcript.Response(segments: []).metadata).isEmpty)
    let foreign = Transcript.Response(metadata: [TurnRecord.metadataKey: 42], segments: [])
    #expect(TurnRecord(metadata: foreign.metadata).isEmpty)
    let garbled = Transcript.Response(metadata: [TurnRecord.metadataKey: "{nope"], segments: [])
    #expect(TurnRecord(metadata: garbled.metadata).isEmpty)
    let absurd = Transcript.Response(
      metadata: [
        TurnRecord.metadataKey:
          #"{"turn": "t", "blocks": [{"at": 1e300, "block": {"type": "text", "text": "x"}}, {"at": 0.5, "block": {}}]}"#
      ],
      segments: []
    )
    #expect(TurnRecord(metadata: absurd.metadata).isEmpty)
  }
}
