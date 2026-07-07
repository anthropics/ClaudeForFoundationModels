// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

/// End-to-end through `LanguageModelSession`: the SSE stream flows through the
/// real executor + translator into the framework's transcript assembly, which
/// is where issue #7 (empty reasoning segments) manifests.
@Suite struct ReasoningTranscriptTests {

  @Test func `thinking stream produces a reasoning entry with text segments`() async throws {
    let model = StubbedClaudeModel(
      fixture: thinkingTurnSSE(thinkingDeltas: ["Let me think. ", "Okay."])
    )
    let session = LanguageModelSession(model: model)

    let response = try await session.respond(to: "hi")
    #expect(response.content == "Hello!")

    let entries = reasoningEntries(in: session.transcript)
    #expect(entries.count == 1)
    let reasoning = try #require(entries.first)
    #expect(reasoningText(in: session.transcript) == "Let me think. Okay.")
    #expect(reasoning.signature == Data(base64Encoded: "c2ln"))
  }

  /// Issue #7 symptom: on models where `thinking.display` defaults to
  /// `omitted` (Sonnet 5, Opus 4.7+), the API streams thinking blocks with no
  /// text deltas — only a signature. The transcript then carries a reasoning
  /// entry with zero text segments.
  @Test func `signature-only thinking stream yields a reasoning entry with no text`() async throws {
    let model = StubbedClaudeModel(fixture: thinkingTurnSSE(thinkingDeltas: []))
    let session = LanguageModelSession(model: model)

    let response = try await session.respond(to: "hi")
    #expect(response.content == "Hello!")

    let entries = reasoningEntries(in: session.transcript)
    #expect(entries.count == 1)
    let reasoning = try #require(entries.first)
    #expect(reasoningText(in: session.transcript).isEmpty)
    #expect(reasoning.signature == Data(base64Encoded: "c2ln"))
  }

  // Replay of redacted thoughts is metadata-driven, so the translator's mark
  // must survive the framework's transcript assembly — this pins that hop.
  @Test func `redacted thinking round-trips to a redacted_thinking replay`() async throws {
    let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let model = StubbedClaudeModel(fixture: redactedThinkingTurnSSE(payload: payload))
    let session = LanguageModelSession(model: model)
    _ = try await session.respond(to: "hi")

    #expect(reasoningEntries(in: session.transcript).count == 1)

    let request = LanguageModelExecutorGenerationRequest.make(transcript: session.transcript)
    let built = try RequestBuilder.build(from: request, model: .sonnet5)
    let assistantBlocks = built.request.messages
      .filter { $0.role == .assistant }
      .flatMap(\.content)
    #expect(assistantBlocks.contains(.redactedThinking(payload)))
  }
}
