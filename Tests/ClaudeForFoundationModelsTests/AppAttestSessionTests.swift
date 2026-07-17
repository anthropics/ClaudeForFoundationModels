// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import Synchronization
import Testing

@testable import ClaudeForFoundationModels

@Suite struct AppAttestSessionTests {
  @Test func `a stored unexpired token is returned without any request`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    let transport = MockTransport(status: 500, body: Data())
    let session = makeSession(store: store, transport: transport)

    #expect(try await session.currentToken() == "tok-1")
    #expect(transport.requests.isEmpty)
  }

  @Test func `first run registers the key and returns the registration token`() async throws {
    let store = InMemoryAppAttestStore()
    let attestation = FakeAttestation()
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "reg-tok")),
    ])
    let session = makeSession(store: store, attestation: attestation, transport: transport)

    let token = try await session.currentToken()

    #expect(token == "reg-tok")
    #expect(try store.keyID(for: "clid_test") == FakeAttestation.keyID)
    #expect(try store.token(for: "clid_test")?.value == "reg-tok")
    #expect(transport.requests.count == 2)

    let challengeRequest = transport.requests[0]
    #expect(challengeRequest.url?.path() == "/v1/oauth/app-attest/challenge")
    let challengeBody = try #require(challengeRequest.httpBody)
    let challengeJSON = try #require(
      JSONSerialization.jsonObject(with: challengeBody) as? [String: String]
    )
    #expect(challengeJSON == ["client_id": "clid_test", "key_id": FakeAttestation.keyID])

    let registerRequest = transport.requests[1]
    #expect(registerRequest.url?.path() == "/v1/oauth/app-attest/register")
    let registerBody = try #require(registerRequest.httpBody)
    let registerJSON = try #require(
      JSONSerialization.jsonObject(with: registerBody) as? [String: String]
    )
    #expect(
      registerJSON["attestation_object"]
        == FakeAttestation.attestationObject.base64EncodedString()
    )

    // Registration binds the attestation to SHA-256 of the raw challenge.
    #expect(
      attestation.attestHashes == [
        Data(hexString: "72cd6e8422c407fb6d098690f1130b7ded7ec2f7f5e1d30bd9d521f015363793")
      ]
    )
  }

  @Test func `steady state mints a token via assertion`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    try store.setToken(.init(value: "stale", expiresAt: .distantPast), for: "clid_test")
    let attestation = FakeAttestation()
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "mint-tok")),
    ])
    let session = makeSession(store: store, attestation: attestation, transport: transport)

    let token = try await session.currentToken()

    #expect(token == "mint-tok")
    #expect(attestation.generateKeyCount == 0)  // no re-attestation
    #expect(transport.requests.count == 2)

    let tokenRequest = transport.requests[1]
    #expect(tokenRequest.url?.path() == "/v1/oauth/token")
    let tokenBody = try #require(tokenRequest.httpBody)
    let form = String(decoding: tokenBody, as: UTF8.self)
    #expect(form.contains("grant_type=urn%3Aanthropic%3Aparams%3Aoauth%3Agrant-type%3Aapp-attest"))
    #expect(form.contains("client_id=clid_test"))
    #expect(!form.contains("+"))  // base64 values must be percent-encoded

    // The assertion binds domain prefix ‖ challenge ‖ client_id ‖ raw key ID.
    #expect(
      attestation.assertionHashes == [
        Data(hexString: "cdc917d0f99d66de670d66db7cfdc90b8f34be288cabe3f1bb63c1e19b2a0b23")
      ]
    )
  }

  @Test func `a rejected assertion retries with a fresh challenge before re-attesting`()
    async throws
  {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let attestation = FakeAttestation()
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"invalid_grant"}"#.utf8)),
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "second-try-tok")),
    ])
    let session = makeSession(store: store, attestation: attestation, transport: transport)

    let token = try await session.currentToken()

    // A single rejection is retried against a fresh challenge, since the
    // opaque 401 can mean an expired or raced challenge, without touching the
    // key.
    #expect(token == "second-try-tok")
    #expect(attestation.generateKeyCount == 0)
    #expect(try store.keyID(for: "clid_test") == FakeAttestation.keyID)
  }

  @Test func `two rejected assertions re-attest once and use the new registration token`()
    async throws
  {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let attestation = FakeAttestation()
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"invalid_grant"}"#.utf8)),
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"invalid_grant"}"#.utf8)),
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "recovered-tok")),
    ])
    let session = makeSession(store: store, attestation: attestation, transport: transport)

    let token = try await session.currentToken()

    #expect(token == "recovered-tok")
    #expect(attestation.generateKeyCount == 1)  // exactly one re-attestation
    #expect(transport.requests.count == 6)
    #expect(transport.requests[5].url?.path() == "/v1/oauth/app-attest/register")
  }

  @Test func `a rejected registration does not persist the key`() async throws {
    let store = InMemoryAppAttestStore()
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"attestation rejected"}"#.utf8)),
    ])
    let session = makeSession(store: store, transport: transport)

    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .register, status: 401, retryAfter: nil)
    ) {
      try await session.currentToken()
    }
    #expect(try store.keyID(for: "clid_test") == nil)
  }

  @Test func `a second rejected assertion within the cooldown does not discard the key`()
    async throws
  {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let attestation = FakeAttestation()
    // First cycle: mint 401 twice -> recovery re-attests, registration also
    // 401s. Second cycle: mint 401s twice again, inside the cooldown.
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"assertion rejected"}"#.utf8)),
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"assertion rejected"}"#.utf8)),
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"attestation rejected"}"#.utf8)),
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"assertion rejected"}"#.utf8)),
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"assertion rejected"}"#.utf8)),
    ])
    let session = makeSession(store: store, attestation: attestation, transport: transport)

    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .register, status: 401, retryAfter: nil)
    ) {
      try await session.currentToken()
    }
    await #expect(throws: AppAttestError.keyInvalidated) {
      try await session.currentToken()
    }
    // The cooldown blocked a second replacement attempt.
    #expect(attestation.generateKeyCount == 1)
    #expect(try store.keyID(for: "clid_test") == FakeAttestation.keyID)
  }

  @Test func `a failed registration backs off instead of re-attesting per request`()
    async throws
  {
    let attestation = FakeAttestation()
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (401, Data(#"{"error":"attestation rejected"}"#.utf8)),
    ])
    let session = makeSession(attestation: attestation, transport: transport)

    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .register, status: 401, retryAfter: nil)
    ) {
      try await session.currentToken()
    }
    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .register, status: 401, retryAfter: nil)
    ) {
      try await session.currentToken()
    }

    // The second attempt was served from the backoff, not the wire.
    #expect(attestation.generateKeyCount == 1)
    #expect(transport.requests.count == 2)
  }

  @Test func `invalidation only discards the token the failed request used`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    let session = makeSession(store: store)
    _ = try await session.currentToken()

    await session.invalidateToken(usedToken: "an-older-token")
    #expect(try store.token(for: "clid_test")?.value == "tok-1")

    await session.invalidateToken(usedToken: "tok-1")
    #expect(try store.token(for: "clid_test") == nil)
  }

  @Test func `an invalidated token is not resurrected by a failed keychain delete`()
    async throws
  {
    let store = UndeletableTokenStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "tok-2")),
    ])
    let session = makeSession(store: store, transport: transport)

    await session.invalidateToken(usedToken: "tok-1")

    // The store still holds tok-1; the suspect flag keeps it from being
    // reloaded.
    #expect(try await session.currentToken() == "tok-2")
  }

  @Test func `a key the Secure Enclave no longer holds re-attests via the recovery ladder`()
    async throws
  {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    // Assertions fail like a key erased from the Secure Enclave; the
    // replacement key's registration token is served without asserting.
    let attestation = FakeAttestation(assertionError: AppAttestError.keyInvalidated)
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "recovered-tok")),
    ])
    let session = makeSession(store: store, attestation: attestation, transport: transport)

    let token = try await session.currentToken()

    #expect(token == "recovered-tok")
    #expect(attestation.generateKeyCount == 1)
    #expect(transport.requests[3].url?.path() == "/v1/oauth/app-attest/register")
  }

  @Test func `a challenge failure during provisioning does not back off`() async throws {
    let attestation = FakeAttestation()
    let transport = MockTransport(responses: [
      (500, Data()),
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "prov-tok")),
    ])
    let session = makeSession(attestation: attestation, transport: transport)

    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .challenge, status: 500, retryAfter: nil)
    ) {
      try await session.currentToken()
    }
    // The next attempt reaches the wire, since the challenge failure did
    // not record a backoff.
    #expect(try await session.currentToken() == "prov-tok")
    #expect(transport.requests.count == 3)
  }

  @Test func `a mint rate limit serves the still-unexpired token`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    // Inside the refresh leeway, but not expired.
    try store.setToken(
      .init(value: "old-tok", expiresAt: Date().addingTimeInterval(30)),
      for: "clid_test"
    )
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (429, Data(#"{"error":"rate_limit_error"}"#.utf8)),
    ])
    let session = makeSession(store: store, transport: transport)

    #expect(try await session.currentToken() == "old-tok")
  }

  @Test func `a token response without expires_in is rejected`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (200, Data(#"{"access_token":"tok","token_type":"Bearer"}"#.utf8)),
    ])
    let session = makeSession(store: store, transport: transport)

    await #expect(throws: AppAttestError.malformedResponse) {
      try await session.currentToken()
    }
  }

  @Test func `a mint 429 carries the server's Retry-After`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody, nil),
      (429, Data(#"{"error":"rate_limit_error"}"#.utf8), ["Retry-After": "7"]),
    ])
    let session = makeSession(store: store, transport: transport)

    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .token, status: 429, retryAfter: 7)
    ) {
      try await session.currentToken()
    }
  }

  @Test func `a Retry-After of zero permits an immediate retry`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody, nil),
      (429, Data(#"{"error":"rate_limit_error"}"#.utf8), ["Retry-After": "0"]),
      (200, WireFixtures.challengeBody, nil),
      (200, WireFixtures.oauthBody(token: "tok-2"), nil),
    ])
    let session = makeSession(store: store, transport: transport)

    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .token, status: 429, retryAfter: 0)
    ) {
      try await session.currentToken()
    }
    // The zero-length cooldown has already elapsed.
    #expect(try await session.currentToken() == "tok-2")
  }

  @Test func `pathological wire durations are sanitized, not trapped`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody, nil),
      (429, Data(#"{"error":"rate_limit_error"}"#.utf8), ["Retry-After": "1e300"]),
    ])
    let session = makeSession(store: store, transport: transport)

    // A malformed header degrades to the fixed fallback window.
    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .token, status: 429, retryAfter: nil)
    ) {
      try await session.currentToken()
    }
  }

  @Test func `a pre-issued challenge saves the fetch round trip`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "tok-1", nextChallengeExpiresIn: 4200)),
      (200, WireFixtures.oauthBody(token: "tok-2")),
    ])
    let session = makeSession(store: store, transport: transport)

    let first = try await session.currentToken()
    await session.invalidateToken(usedToken: first)
    let second = try await session.currentToken()

    #expect(first == "tok-1")
    #expect(second == "tok-2")
    // The renewal posted straight to the token endpoint.
    #expect(transport.requests.count == 3)
    #expect(transport.requests[2].url?.path() == "/v1/oauth/token")
  }

  @Test func `a stale pre-issued challenge falls back to the fetch`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "tok-1", nextChallengeExpiresIn: 5)),
      (200, WireFixtures.challengeBody),
      (200, WireFixtures.oauthBody(token: "tok-2")),
    ])
    let session = makeSession(store: store, transport: transport)

    let first = try await session.currentToken()
    await session.invalidateToken(usedToken: first)
    let second = try await session.currentToken()

    #expect(second == "tok-2")
    #expect(transport.requests.count == 4)
    #expect(transport.requests[2].url?.path() == "/v1/oauth/app-attest/challenge")
  }

  @Test func `a mint rate limit backs off without touching the key`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID(FakeAttestation.keyID, for: "clid_test")
    let attestation = FakeAttestation()
    let transport = MockTransport(responses: [
      (200, WireFixtures.challengeBody),
      (429, Data(#"{"error":"rate_limit_error"}"#.utf8)),
    ])
    let session = makeSession(store: store, attestation: attestation, transport: transport)

    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .token, status: 429, retryAfter: nil)
    ) {
      try await session.currentToken()
    }
    await #expect(
      throws: AppAttestError.requestFailed(endpoint: .token, status: 429, retryAfter: nil)
    ) {
      try await session.currentToken()
    }

    // The second rejection came from the backoff, not the wire, and the
    // key was never implicated.
    #expect(transport.requests.count == 2)
    #expect(attestation.generateKeyCount == 0)
    #expect(try store.keyID(for: "clid_test") == FakeAttestation.keyID)
  }

  @Test func `undeployed endpoints surface as notYetAvailable`() async throws {
    let session = makeSession(transport: MockTransport(status: 404, body: Data()))
    await #expect(throws: AppAttestError.notYetAvailable) {
      try await session.currentToken()
    }
  }

  @Test func `invalidateToken drops the cached and stored token`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setToken(.init(value: "tok-1", expiresAt: .distantFuture), for: "clid_test")
    let session = makeSession(store: store, transport: MockTransport(status: 404, body: Data()))
    #expect(try await session.currentToken() == "tok-1")

    await session.invalidateToken(usedToken: nil)

    #expect(try store.token(for: "clid_test") == nil)
    await #expect(throws: AppAttestError.notYetAvailable) {
      try await session.currentToken()
    }
  }

  @Test func `attestIfNeeded skips when a key id is already stored`() async throws {
    let store = InMemoryAppAttestStore()
    try store.setKeyID("key-1", for: "clid_test")
    let attestation = FakeAttestation()
    let session = makeSession(store: store, attestation: attestation)

    try await session.attestIfNeeded()

    #expect(attestation.generateKeyCount == 0)
  }

  @Test func `unsupported attestation throws on first use`() async throws {
    let session = makeSession(attestation: FakeAttestation(supported: false))
    await #expect(throws: AppAttestError.unsupported) {
      try await session.attestIfNeeded()
    }
  }

  @Test func `concurrent attestIfNeeded calls coalesce onto one key generation`() async throws {
    let attestation = FakeAttestation()
    // The singleflight is the subject; each provision that does run fails at
    // the challenge call.
    let session = makeSession(
      attestation: attestation,
      transport: MockTransport(status: 404, body: Data())
    )

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { try? await session.attestIfNeeded() }
      }
    }
    #expect(attestation.generateKeyCount == 1)
  }

  @Test func `form encoding percent-encodes reserved characters`() {
    let encoded = AppAttestSession.formEncode(["assertion": "a+b/c=", "grant_type": "x:y"])
    #expect(encoded == "assertion=a%2Bb%2Fc%3D&grant_type=x%3Ay")
  }

  @Test func `loose base64 decoding accepts every alphabet and padding`() {
    let bytes = Data([0xFB, 0xEF, 0xFF])
    #expect(AppAttestSession.decodeBase64Loose(bytes.base64EncodedString()) == bytes)
    #expect(
      AppAttestSession.decodeBase64Loose("--__") == AppAttestSession.decodeBase64Loose("++//")
    )
    #expect(AppAttestSession.decodeBase64Loose("AQID") == Data([1, 2, 3]))
    #expect(AppAttestSession.decodeBase64Loose("AQ") == Data([1]))
    #expect(AppAttestSession.decodeBase64Loose("!!") == nil)
  }

  // MARK: - Fixtures

  private func makeSession(
    store: any AppAttestStore = InMemoryAppAttestStore(),
    attestation: any AttestationService = FakeAttestation(),
    transport: any HTTPTransport = MockTransport(status: 500, body: Data())
  ) -> AppAttestSession {
    AppAttestSession(
      clientID: "clid_test",
      baseURL: URL(string: "https://stub.invalid")!,
      attestation: attestation,
      store: store,
      transport: transport
    )
  }

}

extension Data {
  /// Builds data from a hex string; test-support only.
  init(hexString: String) {
    var bytes: [UInt8] = []
    var index = hexString.startIndex
    while index < hexString.endIndex {
      let next = hexString.index(index, offsetBy: 2)
      bytes.append(UInt8(hexString[index..<next], radix: 16)!)
      index = next
    }
    self.init(bytes)
  }
}

// MARK: - Test doubles

/// Ignores `deleteToken` so a seeded token survives invalidation attempts.
final class UndeletableTokenStore: AppAttestStore {
  private let inner = InMemoryAppAttestStore()

  func keyID(for clientID: String) throws -> String? { try inner.keyID(for: clientID) }
  func setKeyID(_ keyID: String, for clientID: String) throws {
    try inner.setKeyID(keyID, for: clientID)
  }
  func token(for clientID: String) throws -> StoredToken? { try inner.token(for: clientID) }
  func setToken(_ token: StoredToken, for clientID: String) throws {
    try inner.setToken(token, for: clientID)
  }
  func deleteToken(for clientID: String) throws {}
}

final class InMemoryAppAttestStore: AppAttestStore {
  private struct Entry {
    var keyID: String?
    var token: StoredToken?
  }
  private let entries = Mutex<[String: Entry]>([:])

  func keyID(for clientID: String) throws -> String? {
    entries.withLock { $0[clientID]?.keyID }
  }
  func setKeyID(_ keyID: String, for clientID: String) throws {
    entries.withLock { $0[clientID, default: .init()].keyID = keyID }
  }
  func token(for clientID: String) throws -> StoredToken? {
    entries.withLock { $0[clientID]?.token }
  }
  func setToken(_ token: StoredToken, for clientID: String) throws {
    entries.withLock { $0[clientID, default: .init()].token = token }
  }
  func deleteToken(for clientID: String) throws {
    entries.withLock { $0[clientID]?.token = nil }
  }
}

final class FakeAttestation: AttestationService {
  /// Standard base64 of 32 bytes of 0x07, decodable like a real key ID.
  static let keyID = Data(repeating: 0x07, count: 32).base64EncodedString()
  static let attestationObject = Data("fake-attestation".utf8)
  static let assertionObject = Data("fake-assertion".utf8)

  let isSupported: Bool
  /// Thrown from every `generateAssertion` call when set, mimicking a
  /// Secure Enclave key that no longer exists.
  let assertionError: (any Error)?
  private let state = Mutex<(keys: Int, attest: [Data], assertions: [Data])>((0, [], []))

  init(supported: Bool = true, assertionError: (any Error)? = nil) {
    self.isSupported = supported
    self.assertionError = assertionError
  }

  var generateKeyCount: Int { state.withLock { $0.keys } }
  var attestHashes: [Data] { state.withLock { $0.attest } }
  var assertionHashes: [Data] { state.withLock { $0.assertions } }

  func generateKey() async throws -> String {
    state.withLock { $0.keys += 1 }
    // Suspends before returning, like the real seconds-long call.
    try? await Task.sleep(for: .milliseconds(50))
    return Self.keyID
  }
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
    state.withLock { $0.attest.append(clientDataHash) }
    return Self.attestationObject
  }
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    state.withLock { $0.assertions.append(clientDataHash) }
    if let assertionError { throw assertionError }
    return Self.assertionObject
  }
}
