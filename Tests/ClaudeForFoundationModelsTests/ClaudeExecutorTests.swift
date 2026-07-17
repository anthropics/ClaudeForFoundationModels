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

  // MARK: - App Attest

  @Test func `appAttest sends a bearer token from the store`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    let transport = MockTransport(body: okStream)
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: transport,
        auth: .appAttest(clientID: "clid_test"),
        attestSession: attestSession(store: store)
      )
    )

    _ = try await session.respond(to: "hi")

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
  }

  @Test func `appAttest without a credential fails with attestationFailed`() async throws {
    let transport = MockTransport(body: okStream)
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: transport,
        auth: .appAttest(clientID: "clid_test"),
        attestSession: attestSession(store: InMemoryAppAttestStore())
      )
    )

    let error = try await #require(throws: ClaudeError.self) {
      _ = try await session.respond(to: "hi")
    }
    guard case .attestationFailed = error else {
      Issue.record("expected attestationFailed, got \(error)")
      return
    }
    #expect(transport.lastRequest == nil)
  }

  @Test func `a pre-stream 401 mints a fresh token and retries exactly once`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    let transport = MockTransport(responses: [
      (401, authErrorBody),
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "tok-2")),
      (200, okStream),
    ])
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: transport,
        auth: .appAttest(clientID: "clid_test"),
        attestSession: attestSession(store: store, transport: transport)
      )
    )

    let response = try await session.respond(to: "hi")

    #expect(response.content == "Hi")
    #expect(transport.requests.count == 4)
    // The retry carries a freshly minted token, not the rejected one.
    #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
    #expect(transport.requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer tok-2")
  }

  @Test func `an auth error before any channel write is retried`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    // A ping arrives before the auth error. It writes nothing to the
    // channel, so the retry should still fire.
    let transport = MockTransport(responses: [
      (200, pingThenAuthErrorBody),
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "tok-2")),
      (200, okStream),
    ])
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: transport,
        auth: .appAttest(clientID: "clid_test"),
        attestSession: attestSession(store: store, transport: transport)
      )
    )

    let response = try await session.respond(to: "hi")

    #expect(response.content == "Hi")
    #expect(transport.requests.count == 4)
    #expect(transport.requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer tok-2")
  }

  @Test func `an authentication error after stream content is not retried`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    let transport = MockTransport(responses: [
      (200, midStreamAuthErrorBody),
      (200, okStream),
    ])
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: transport,
        auth: .appAttest(clientID: "clid_test"),
        attestSession: attestSession(store: store)
      )
    )

    await #expect(throws: ClaudeError.self) {
      _ = try await session.respond(to: "hi")
    }
    // The channel already received content, so replaying would duplicate
    // it. The rejected token still gets invalidated.
    #expect(transport.requests.count == 1)
    #expect(try store.token(for: "clid_test") == nil)
  }

  @Test func `one attest session is shared per client id`() throws {
    let clientID = "clid_\(UUID().uuidString)"
    var made = 0
    func makeSession() -> AppAttestSession {
      made += 1
      return AppAttestSession(
        clientID: clientID,
        baseURL: ClaudeLanguageModel.defaultBaseURL,
        attestation: FakeAttestation(),
        store: InMemoryAppAttestStore()
      )
    }

    let first = try AppAttestSession.shared(
      clientID: clientID,
      baseURL: ClaudeLanguageModel.defaultBaseURL,
      makeSession: makeSession
    )
    let second = try AppAttestSession.shared(
      clientID: clientID,
      baseURL: ClaudeLanguageModel.defaultBaseURL,
      makeSession: makeSession
    )
    let other = try AppAttestSession.shared(
      clientID: "clid_\(UUID().uuidString)",
      baseURL: ClaudeLanguageModel.defaultBaseURL,
      makeSession: makeSession
    )

    #expect(first === second)
    #expect(first !== other)
    #expect(made == 2)
  }

  // MARK: - Fixtures

  /// The default transport answers 404 so no auth wire flow leaves the
  /// process; pass a transport to script the OAuth exchange.
  private func attestSession(
    store: any AppAttestStore,
    transport: MockTransport = MockTransport(status: 404, body: Data())
  ) -> AppAttestSession {
    AppAttestSession(
      clientID: "clid_test",
      baseURL: ClaudeLanguageModel.defaultBaseURL,
      attestation: FakeAttestation(),
      store: store,
      transport: transport
    )
  }

  private let okStream = textTurn(deltas: ["Hi"])

  private let authErrorBody = Data(
    #"{"type":"error","error":{"type":"authentication_error","message":"expired"}}"#.utf8
  )

  /// Fails authentication after only a ping. Nothing has reached the
  /// channel, so a transparent retry is still safe.
  private let pingThenAuthErrorBody = sseBody([
    ["event: ping", #"data: {"type":"ping"}"#],
    [
      "event: error",
      #"data: {"type":"error","error":{"type":"authentication_error","message":"expired"}}"#,
    ],
  ])

  /// A stream that delivers content before failing authentication: the shape
  /// where a transparent retry would corrupt the channel.
  private let midStreamAuthErrorBody = sseBody([
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
      "event: error",
      #"data: {"type":"error","error":{"type":"authentication_error","message":"revoked"}}"#,
    ],
  ])
}
