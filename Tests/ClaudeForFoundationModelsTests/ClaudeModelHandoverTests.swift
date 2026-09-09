// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

@Suite struct ClaudeModelHandoverTests {
  // A model can decline partway through its answer. The stream then carries a
  // `fallback` block, and the fallback model continues from the text so far.
  @Test func `a handover holds its place and names the model that finished`() async throws {
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        fixture: turn([
          .text(["Sure, here"]),
          .fallback(from: "claude-sonnet-5", to: "claude-opus-4-8", category: "cyber"),
          .text([" it is."]),
        ])
      )
    )

    _ = try await session.respond(to: "hi")

    let response = try #require(responseEntries(in: session.transcript).last)
    let texts = response.segments.map { segment -> String? in
      if case .text(let text) = segment { text.content } else { nil }
    }
    #expect(texts == ["Sure, here", "", " it is."])
    #expect(
      response.segments.map { response.claudeHandover(for: $0)?.toModelID }
        == [nil, "claude-opus-4-8", nil]
    )
    #expect(response.claudeHandovers.count == 1)
    let handover = try #require(response.claudeHandovers.first)
    #expect(handover.fromModelID == "claude-sonnet-5")
    #expect(handover.toModelID == "claude-opus-4-8")
    #expect(handover.reason == .refusal(category: "cyber"))
    #expect(response.claudeModelID == "claude-opus-4-8")
  }

  @Test func `without a handover the model the stream started on served the response`()
    async throws
  {
    let session = LanguageModelSession(model: StubbedClaudeModel(fixture: turn([.text(["Hi!"])])))
    _ = try await session.respond(to: "hi")
    let response = try #require(responseEntries(in: session.transcript).last)
    #expect(response.claudeHandovers.isEmpty)
    #expect(response.claudeModelID == "claude-sonnet-5")

    // After a fallback, the API can route a conversation straight to the
    // fallback model. That response has no handover, and its stream names the
    // fallback model from the start.
    let routed = LanguageModelSession(
      model: StubbedClaudeModel(fixture: turn([.text(["Hi!"])], model: "claude-opus-4-8"))
    )
    _ = try await routed.respond(to: "hi")
    let routedResponse = try #require(responseEntries(in: routed.transcript).last)
    #expect(routedResponse.claudeHandovers.isEmpty)
    #expect(routedResponse.claudeModelID == "claude-opus-4-8")
  }

  @Test func `a handover's reason reads what the API sent`() throws {
    func handover(trigger: JSONValue?) throws -> ClaudeModelHandover {
      var fields: [String: JSONValue] = [
        "type": "fallback", "from": ["model": "claude-a"], "to": ["model": "claude-b"],
      ]
      fields["trigger"] = trigger
      return try #require(ClaudeModelHandover(TurnRecord.Kind(.object(fields))))
    }
    #expect(
      try handover(trigger: ["type": "refusal", "category": "bio"]).reason
        == .refusal(category: "bio")
    )
    #expect(
      try handover(trigger: ["type": "refusal", "category": nil]).reason == .refusal(category: nil)
    )
    #expect(
      try handover(trigger: ["type": "overloaded"]).reason == .unrecognized(type: "overloaded")
    )
    // The API can leave the trigger out.
    #expect(try handover(trigger: nil).reason == nil)
    // A block that names no models is no handover.
    #expect(ClaudeModelHandover(TurnRecord.Kind(["type": "fallback"])) == nil)
  }

  @Test func `a handover goes back on the next turn, with the fallbacks opt-in`() async throws {
    let transport = MockTransport(responses: [
      (
        status: 200,
        body: turn([
          .text(["Sure"]),
          .fallback(from: "claude-sonnet-5", to: "claude-opus-4-8", category: nil),
          .text([" thing."]),
        ])
      ),
      (status: 200, body: turn([.text(["You're welcome."])])),
    ])
    // This session names no fallbacks, so only the replayed block opts in.
    let session = LanguageModelSession(model: StubbedClaudeModel(transport: transport))

    _ = try await session.respond(to: "hi")
    _ = try await session.respond(to: "thanks")

    #expect(transport.requests.count == 2)
    #expect(transport.requests.first?.value(forHTTPHeaderField: "anthropic-beta") == nil)
    #expect(
      transport.lastRequest?.value(forHTTPHeaderField: "anthropic-beta") == Fallbacks.betaHeader
    )
    let replayed = try replayedAssistantContent(in: transport)
    #expect(replayed.count == 1)
    #expect(replayed.first?.map { $0["type"] ?? nil } == ["text", "fallback", "text"])
  }
}
