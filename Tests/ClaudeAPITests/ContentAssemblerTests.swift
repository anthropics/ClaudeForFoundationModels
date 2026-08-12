// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeAPI

@Suite struct ContentAssemblerTests {
  private func assemble(_ eventJSON: [String]) throws -> [JSONValue] {
    var assembler = ContentAssembler()
    return try eventJSON.compactMap { json in
      assembler.consume(try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8)))
    }
  }

  @Test func `text deltas and citations fold into the text block`() throws {
    let blocks = try assemble([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"It is "}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"sunny."}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","encrypted_index":"a"}}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","encrypted_index":"b"}}}"#,
      #"{"type":"content_block_stop","index":0}"#,
    ])
    #expect(
      blocks == [
        [
          "type": "text",
          "text": "It is sunny.",
          "citations": [
            ["type": "web_search_result_location", "encrypted_index": "a"],
            ["type": "web_search_result_location", "encrypted_index": "b"],
          ],
        ]
      ]
    )
  }

  @Test func `streamed tool input replaces the start block's placeholder`() throws {
    let blocks = try assemble([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{}}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":" \"weather\"}"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
    ])
    #expect(
      blocks == [
        [
          "type": "server_tool_use", "id": "srv_1", "name": "web_search",
          "input": ["query": "weather"],
        ]
      ]
    )
  }

  @Test func `input delivered whole in the start block is kept when no deltas follow`() throws {
    let blocks = try assemble([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{"query":"weather"}}}"#,
      #"{"type":"content_block_stop","index":0}"#,
    ])
    let block = try #require(blocks.first)
    #expect(block["input"] == ["query": "weather"])
  }

  @Test func `thinking text and signature fold into the thinking block`() throws {
    let blocks = try assemble([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me "}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"think."}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"c2ln"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
    ])
    #expect(blocks == [["type": "thinking", "thinking": "Let me think.", "signature": "c2ln"]])
  }

  @Test func `blocks that arrive whole and unknown block types are kept as sent`() throws {
    let blocks = try assemble([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[{"type":"web_search_result","url":"https://a.example","encrypted_content":"opaque","page_age":null}]}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"future_block","payload":{"n":1}}}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"future_delta","x":1}}"#,
      #"{"type":"content_block_stop","index":1}"#,
    ])
    #expect(
      blocks == [
        [
          "type": "web_search_tool_result",
          "tool_use_id": "srv_1",
          "content": [
            [
              "type": "web_search_result", "url": "https://a.example",
              "encrypted_content": "opaque", "page_age": nil,
            ]
          ],
        ],
        ["type": "future_block", "payload": ["n": 1]],
      ]
    )
  }

  @Test func `interleaved blocks come out in index order of completion`() throws {
    let blocks = try assemble([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking."}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{"query":"q"}}}"#,
      #"{"type":"content_block_stop","index":1}"#,
      #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Done."}}"#,
      #"{"type":"content_block_stop","index":2}"#,
    ])
    #expect(blocks.map { $0["type"] } == ["text", "server_tool_use", "text"])
  }

  @Test func `a text block that received no text is omitted`() throws {
    let blocks = try assemble([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"ping","input":{}}}"#,
      #"{"type":"content_block_stop","index":1}"#,
    ])
    #expect(blocks.map { $0["type"] } == ["tool_use"])
  }

  @Test func `a continuation response appends after the paused content`() throws {
    let blocks = try assemble([
      #"{"type":"message_start","message":{"id":"m1","model":"x","role":"assistant","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{"query":"q"}}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      // The continuation's indices start over at 0.
      #"{"type":"message_start","message":{"id":"m2","model":"x","role":"assistant","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[]}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Done."}}"#,
      #"{"type":"content_block_stop","index":1}"#,
    ])
    #expect(blocks.map { $0["type"] } == ["server_tool_use", "web_search_tool_result", "text"])
  }

  @Test func `only the stop of a started block yields it`() throws {
    var assembler = ContentAssembler()
    func consume(_ json: String) throws -> JSONValue? {
      assembler.consume(try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8)))
    }
    #expect(
      try consume(
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
      ) == nil
    )
    #expect(
      try consume(
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#
      ) == nil
    )
    #expect(
      try consume(#"{"type":"content_block_stop","index":0}"#) == ["type": "text", "text": "x"]
    )
    // A stop for an index that never started (or was already stopped) is not
    // a completion.
    #expect(try consume(#"{"type":"content_block_stop","index":0}"#) == nil)
  }
}
