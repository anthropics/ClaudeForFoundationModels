// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeForFoundationModels

@Suite struct ClaudeServerToolSegmentTests {
  @Test func `segments expose the tool name for generic rendering`() {
    #expect(
      ClaudeServerToolSegment(id: "s", content: .webSearch(.init(query: "q"))).toolName
        == "web_search"
    )
    #expect(
      ClaudeServerToolSegment(
        id: "s",
        content: .webFetch(.init(url: URL(string: "https://example.com")!))
      )
      .toolName == "web_fetch"
    )
    #expect(
      ClaudeServerToolSegment(id: "s", content: .codeExecution(.init(code: "print(1)"))).toolName
        == "code_execution"
    )
    #expect(
      ClaudeServerToolSegment(id: "s", content: .unrecognized(.init(toolName: "future_tool")))
        .toolName == "future_tool"
    )
  }
}
