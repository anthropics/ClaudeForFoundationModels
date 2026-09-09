// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
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

  @Test func `fallbacks reach the wire with the opt-in, after a proxy's own betas`() async throws {
    let transport = MockTransport(body: okStream)
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: transport,
        auth: .proxied(headers: ["Anthropic-Beta": "feature-1"]),
        model: .opus5,
        fallbacks: [.opus4_8]
      )
    )

    _ = try await session.respond(to: "hi")

    let request = try #require(transport.lastRequest)
    #expect(
      request.value(forHTTPHeaderField: "anthropic-beta")
        == "feature-1,\(Fallbacks.betaHeader)"
    )
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "claude-opus-5")
    let fallbacks = try #require(json["fallbacks"] as? [[String: Any]])
    #expect(fallbacks.count == 1)
    #expect(fallbacks.first?["model"] as? String == "claude-opus-4-8")
    #expect(fallbacks.first?.count == 1)
  }

  // The profile's beta goes after the proxy's and the fallbacks' betas. The
  // configured profile replaces a proxy header of the same name, however it's
  // spelled, so the request carries one profile.
  @Test func `a user profile reaches the wire, after the other betas`() async throws {
    let transport = MockTransport(body: okStream)
    let session = LanguageModelSession(
      model: StubbedClaudeModel(
        transport: transport,
        auth: .proxied(
          headers: ["Anthropic-Beta": "feature-1", "Anthropic-User-Profile-Id": "uprof_stale"]
        ),
        model: .opus5,
        fallbacks: [.opus4_8],
        userProfileID: "uprof_test_1"
      )
    )

    _ = try await session.respond(to: "hi")

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "anthropic-user-profile-id") == "uprof_test_1")
    #expect(
      request.value(forHTTPHeaderField: "anthropic-beta")
        == "feature-1,\(Fallbacks.betaHeader),\(UserProfiles.betaHeader)"
    )
    let names = request.allHTTPHeaderFields?.keys
      .filter {
        $0.caseInsensitiveCompare(HeaderName.userProfileID) == .orderedSame
      }
    #expect(names?.count == 1)
  }

  @Test func `setting a header replaces it, however its name is spelled`() {
    #expect(
      ClaudeExecutor.headers(
        ["Anthropic-User-Profile-Id": "uprof_old", "X-App-Token": "abc"],
        setting: HeaderName.userProfileID,
        to: "uprof_new"
      ) == ["Anthropic-User-Profile-Id": "uprof_new", "X-App-Token": "abc"]
    )
    #expect(
      ClaudeExecutor.headers([:], setting: HeaderName.userProfileID, to: "uprof_new")
        == ["anthropic-user-profile-id": "uprof_new"]
    )
  }

  @Test func `a beta joins anthropic-beta once, however the header is spelled`() {
    #expect(
      ClaudeExecutor.headers(["X-App-Token": "abc"], addingBetas: []) == ["X-App-Token": "abc"]
    )
    #expect(ClaudeExecutor.headers([:], addingBetas: ["beta-1"]) == ["anthropic-beta": "beta-1"])
    #expect(
      ClaudeExecutor.headers(
        ["ANTHROPIC-BETA": "beta-0, beta-1"],
        addingBetas: ["beta-1", "beta-2"]
      )
        == ["ANTHROPIC-BETA": "beta-0,beta-1,beta-2"]
    )
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
    // A ping and a message_start (reporting 100 prompt tokens) arrive before
    // the auth error. Neither writes to the channel, so the retry still
    // fires, and the abandoned attempt's usage must not be counted.
    let transport = MockTransport(responses: [
      (200, preludeThenAuthErrorBody),
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
    // Only the response that was actually read counts toward usage.
    #expect(session.usage.input.totalTokenCount == 10)
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

  @Test func `a continuation rejected for auth is retried with a fresh token`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    let transport = MockTransport(responses: [
      (200, turn([.search(id: "srv_1", query: "q")], stopReason: "pause_turn")),
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

    let response = try await session.respond(to: "research this")

    #expect(response.content == "Hi")
    #expect(transport.requests.count == 5)
    // The first response already streamed, but the rejected continuation
    // itself wrote nothing, so it is the one retried.
    #expect(transport.requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer tok-2")
    #expect(try replayedAssistantContent(in: transport).count == 1)
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

  /// Fails authentication after only a ping and a message_start reporting
  /// 100 prompt tokens. Nothing has reached the channel, so a transparent
  /// retry is still safe.
  private let preludeThenAuthErrorBody = sseBody([
    ["event: ping", #"data: {"type":"ping"}"#],
    [
      "event: message_start",
      #"data: {"type":"message_start","message":{"id":"msg_0","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":1}}}"#,
    ],
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
