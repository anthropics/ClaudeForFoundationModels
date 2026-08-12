// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

@Suite struct ClaudeServerToolActivityTests {
  private let exampleURL = URL(string: "https://example.com")!

  @Test func `a web search pairs its results by id`() throws {
    let activity = ClaudeServerToolActivity.derive(
      from: record([
        serverToolUse(id: "srv_1", name: "web_search", input: ["query": "weather"]),
        [
          "type": "web_search_tool_result", "tool_use_id": "srv_1",
          "content": [
            [
              "type": "web_search_result", "url": "https://example.com", "title": "Example",
              "page_age": "June 7, 2026", "encrypted_content": "opaque",
            ]
          ],
        ],
      ])
      .blocks
    )
    #expect(
      activity == [
        .init(
          id: "srv_1",
          content: .webSearch(
            .init(
              query: "weather",
              outcome: .results([.init(url: exampleURL, title: "Example", pageAge: "June 7, 2026")])
            )
          )
        )
      ]
    )
    let first = try #require(activity.first)
    #expect(first.toolName == "web_search")
  }

  @Test func `a call without a result has no outcome`() {
    let activity = ClaudeServerToolActivity.derive(
      from: record([
        serverToolUse(id: "srv_1", name: "web_fetch", input: ["url": "https://example.com"])
      ])
      .blocks
    )
    #expect(
      activity == [.init(id: "srv_1", content: .webFetch(.init(url: exampleURL, outcome: nil)))]
    )
  }

  @Test func `tool errors become failures`() {
    let activity = ClaudeServerToolActivity.derive(
      from: record([
        serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"]),
        [
          "type": "web_search_tool_result", "tool_use_id": "srv_1",
          "content": ["type": "web_search_tool_result_error", "error_code": "max_uses_exceeded"],
        ],
        serverToolUse(id: "srv_2", name: "code_execution", input: ["code": "1/0"]),
        [
          "type": "code_execution_tool_result", "tool_use_id": "srv_2",
          "content": ["type": "code_execution_tool_result_error", "error_code": "unavailable"],
        ],
      ])
      .blocks
    )
    #expect(
      activity.map(\.content) == [
        .webSearch(.init(query: "q", outcome: .failure(errorCode: "max_uses_exceeded"))),
        .codeExecution(.init(code: "1/0", outcome: .failure(errorCode: "unavailable"))),
      ]
    )
  }

  @Test func `web fetch and code execution results decode`() {
    let activity = ClaudeServerToolActivity.derive(
      from: record([
        serverToolUse(id: "srv_1", name: "web_fetch", input: ["url": "https://example.com"]),
        [
          "type": "web_fetch_tool_result", "tool_use_id": "srv_1",
          "content": [
            "type": "web_fetch_result", "url": "https://example.com/",
            "retrieved_at": "2026-06-08T00:00:00Z",
            "content": [
              "type": "document", "title": "Example",
              "source": ["type": "base64", "media_type": "application/pdf", "data": "JVBERi0="],
            ],
          ],
        ],
        serverToolUse(id: "srv_2", name: "code_execution", input: ["code": "print(1)"]),
        [
          "type": "code_execution_tool_result", "tool_use_id": "srv_2",
          "content": [
            "type": "code_execution_result", "stdout": "1\n", "stderr": "", "return_code": 0,
          ],
        ],
      ])
      .blocks
    )
    #expect(
      activity.map(\.content) == [
        .webFetch(
          .init(
            url: exampleURL,
            outcome: .document(
              .init(
                url: URL(string: "https://example.com/"),
                title: "Example",
                text: "JVBERi0=",
                mediaType: "application/pdf",
                retrievedAt: "2026-06-08T00:00:00Z"
              )
            )
          )
        ),
        .codeExecution(
          .init(code: "print(1)", outcome: .output(.init(stdout: "1\n", stderr: "", returnCode: 0)))
        ),
      ]
    )
  }

  @Test func `an unknown tool surfaces by name`() throws {
    let activity = ClaudeServerToolActivity.derive(
      from: record([
        ["type": "mcp_tool_use", "id": "m_1", "name": "future_tool", "input": ["x": 1]],
        ["type": "mcp_tool_result", "tool_use_id": "m_1", "content": ["ok": true]],
      ])
      .blocks
    )
    #expect(
      activity == [
        .init(
          id: "m_1",
          content: .unrecognized(.init(toolName: "future_tool", resultType: "mcp_tool_result"))
        )
      ]
    )
    #expect(activity.first?.toolName == "future_tool")
  }

  @Test func `a known tool whose result doesn't decode is demoted rather than dropped`() throws {
    let activity = ClaudeServerToolActivity.derive(
      from: record([
        serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"]),
        ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": ["surprise": 1]],
      ])
      .blocks
    )
    #expect(
      activity.map(\.content) == [
        .unrecognized(.init(toolName: "web_search", resultType: "web_search_tool_result"))
      ]
    )
  }

  @Test func `a hit whose url doesn't parse is dropped, not the whole result`() throws {
    let activity = ClaudeServerToolActivity.derive(
      from: record([
        serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"]),
        [
          "type": "web_search_tool_result", "tool_use_id": "srv_1",
          "content": [
            ["type": "web_search_result", "url": "", "title": "Bad"],
            ["type": "web_search_result", "url": "https://example.com", "title": "Good"],
          ],
        ],
      ])
      .blocks
    )
    #expect(
      activity.map(\.content) == [
        .webSearch(
          .init(
            query: "q",
            outcome: .results([.init(url: exampleURL, title: "Good", pageAge: nil)])
          )
        )
      ]
    )
  }

  @Test func `results are paired across turns by the transcript but not by one response`() throws {
    // The model called a client tool alongside the search, so the result
    // arrived in the following response.
    let toolUse: JSONValue = ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]]
    let secondTurn: [JSONValue] = [
      ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": []],
      ["type": "text", "text": "Done."],
    ]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"])]),
      try recordedToolCall(toolUse, at: 1),
      .toolOutput(
        .init(id: "toolu_1", toolName: "ping", segments: [.text(.init(content: "pong"))])
      ),
      recordedResponse(secondTurn, turn: "turn-2"),
    ])

    let paired = ClaudeServerToolActivity(
      id: "srv_1",
      content: .webSearch(.init(query: "q", outcome: .results([])))
    )
    #expect(transcript.claudeServerToolActivity == [paired])

    let responses = responseEntries(in: transcript)
    #expect(
      responses.map { response in
        response.segments.map { response.claudeServerToolActivity(for: $0) }
      } == [
        [.init(id: "srv_1", content: .webSearch(.init(query: "q", outcome: nil)))],
        [nil],
      ]
    )
    // Only an empty segment whose id is a recorded call's is a placeholder.
    let first = try #require(responses.first)
    #expect(first.claudeServerToolActivity(for: .text(.init(id: "other", content: ""))) == nil)
    #expect(first.claudeServerToolActivity(for: .text(.init(id: "srv_1", content: "prose"))) == nil)
  }

  @Test func `text and client tool blocks are not activity`() {
    let activity = ClaudeServerToolActivity.derive(
      from: record([
        ["type": "text", "text": "hi"],
        ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]],
      ])
      .blocks
    )
    #expect(activity.isEmpty)
  }
}
