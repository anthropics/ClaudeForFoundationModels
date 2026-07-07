// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

@Suite struct ClaudeExecutorTests {
  @Test func `api key auth sends x-api-key`() async throws {
    let transport = MockTransport(body: okStream)
    let session = LanguageModelSession(
      model: StubbedClaudeModel(transport: transport, auth: .apiKey("sk-test"))
    )

    _ = try await session.respond(to: "hi")

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
  }

  @Test func `proxied auth sends the proxy headers and no api key`() async throws {
    let transport = MockTransport(body: okStream)
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: transport,
        auth: .proxied(headers: ["X-App-Token": "abc"])
      )
    )

    _ = try await session.respond(to: "hi")

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "X-App-Token") == "abc")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
  }

  @Test func `an empty api key fails before any request is sent`() async throws {
    let transport = MockTransport(body: okStream)
    let session = LanguageModelSession(
      model: StubbedClaudeModel(transport: transport, auth: .apiKey(""))
    )

    let error = try await #require(throws: ClaudeError.self) {
      _ = try await session.respond(to: "hi")
    }
    guard case .missingCredential = error else {
      Issue.record("expected missingCredential, got \(error)")
      return
    }
    #expect(transport.lastRequest == nil)  // auth is checked before the transport runs
  }

  @Test func `a streamed response reaches the session`() async throws {
    let session = LanguageModelSession(model: StubbedClaudeModel(fixture: okStream))

    let response = try await session.respond(to: "hi")

    #expect(response.content == "Hi")
  }

  @Test func `an API error status is mapped to a typed LanguageModelError`() async throws {
    let transport = MockTransport(
      status: 429,
      body: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#.utf8)
    )
    let session = LanguageModelSession(model: StubbedClaudeModel(transport: transport))

    let error = try await #require(throws: LanguageModelError.self) {
      _ = try await session.respond(to: "hi")
    }
    guard case .rateLimited = error else {
      Issue.record("expected rateLimited, got \(error)")
      return
    }
  }

  // MARK: - Fixtures

  private let okStream = textTurn(deltas: ["Hi"])
}
