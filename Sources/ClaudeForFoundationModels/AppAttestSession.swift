// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import CryptoKit
import Foundation
import Synchronization

/// Manages the App Attest credential lifecycle for ``AuthMode/appAttest(clientID:)``.
///
/// Owns key and token persistence (via ``AppAttestStore``), device
/// attestation and registration, and token refresh.
///
/// Flow:
/// 1. First run (a blocking Apple round-trip): generate a Secure Enclave
///    key → fetch challenge → attest → register. Registration returns the
///    install's first bearer token; the key ID persists only after the
///    server accepts it.
/// 2. Steady state: fetch challenge → sign it → exchange the assertion at
///    the token endpoint.
///
/// Refresh and registration are each singleflighted: the server's
/// `sign_count` check is strictly increasing, so parallel assertions from
/// one key reject, and parallel registrations waste rate-limited Apple
/// attestations.
actor AppAttestSession {
  /// One session per client ID, process-wide. A client ID names one Secure
  /// Enclave key, and every assertion for that key must flow through the
  /// same singleflight; separate sessions would race the server's
  /// `sign_count` check.
  static func shared(
    clientID: String,
    baseURL: URL,
    makeSession: () -> AppAttestSession
  ) throws -> AppAttestSession {
    try sessions.withLock { cache in
      if let existing = cache[clientID] {
        // One client ID names one key; a second base URL would split that
        // key's assertions across hosts. A trailing slash doesn't change
        // the host.
        guard normalized(existing.baseURL) == normalized(baseURL) else {
          throw AppAttestError.conflictingBaseURL
        }
        return existing
      }
      let session = makeSession()
      cache[clientID] = session
      return session
    }
  }

  private static let sessions = Mutex<[String: AppAttestSession]>([:])

  private static func normalized(_ url: URL) -> String {
    let string = url.absoluteString
    return string.hasSuffix("/") ? String(string.dropLast()) : string
  }

  init(
    clientID: String,
    baseURL: URL,
    attestation: any AttestationService,
    store: any AppAttestStore = KeychainAppAttestStore(),
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.clientID = clientID
    self.baseURL = baseURL
    self.attestation = attestation
    self.store = store
    self.transport = transport
  }

  // MARK: - Credential API

  /// Idempotent. Generates and registers a key if none is persisted; no-op
  /// otherwise. The first call per install includes Apple's attestation
  /// round-trip, which takes several seconds.
  func attestIfNeeded() async throws {
    _ = try await ensureKeyID()
  }

  /// Returns a valid bearer token, refreshing if needed. Concurrent callers
  /// coalesce onto a single in-flight refresh; the shared refresh is not
  /// cancelled when one waiter is.
  func currentToken() async throws -> String {
    if credentials.token == nil, !credentials.storedTokenSuspect {
      credentials.token = try? store.token(for: clientID)
    }
    if let token = validToken() { return token.value }
    if let refreshInFlight { return try await refreshInFlight.value }
    let task = Task { try await refresh() }
    refreshInFlight = task
    defer { if refreshInFlight == task { refreshInFlight = nil } }
    return try await task.value
  }

  /// Call when a request 401s. `usedToken` is the bearer the failed request
  /// carried: a mismatch with the cache means a newer token already exists
  /// and nothing is discarded. An in-flight refresh keeps running, since
  /// its token is newer than the one that failed.
  func invalidateToken(usedToken: String?) {
    if let usedToken, let current = credentials.token?.value, current != usedToken {
      return
    }
    credentials.token = nil
    // The keychain delete is best-effort and unverifiable; until a fresh
    // mint lands, the stored token may still be the revoked one.
    credentials.storedTokenSuspect = true
    try? store.deleteToken(for: clientID)
  }

  // MARK: - State

  private struct CredentialState {
    var keyID: String?
    var token: StoredToken?
    /// Blocks reloading the stored token after an invalidation whose
    /// keychain delete may have failed.
    var storedTokenSuspect = false
  }

  /// A time window on a monotonic clock, so wall-clock corrections don't
  /// shorten or lengthen it.
  private struct Cooldown {
    private var until: ContinuousClock.Instant?

    var isActive: Bool {
      guard let until else { return false }
      return ContinuousClock.now < until
    }

    mutating func start(for window: Duration) { until = .now + window }
  }

  /// Pacing for expensive recovery actions. Windows come from the server's
  /// `Retry-After` when it sends one, else from fixed fallbacks.
  private struct RecoveryPacing {
    /// Fallback for the per-device mint limit's one-minute window.
    static let mintRateLimitFallback: Duration = .seconds(60)
    /// Fallback for a registration-quota rejection without a
    /// `Retry-After`.
    static let registrationQuotaFallback: Duration = .seconds(900)
    /// Minimum spacing between key replacements, which are expensive (an
    /// Apple attestation plus a registration-quota slot) and can be
    /// triggered by a transient condition behind the opaque 401.
    static let keyReplacementWindow: Duration = .seconds(600)

    var mintRateLimit = Cooldown()
    var keyReplacement = Cooldown()

    private var provisionBackoff = Cooldown()
    private var provisionError: (any Error)?

    /// The failure to replay while its backoff is still running, if any.
    func pendingProvisionFailure() -> (any Error)? {
      provisionBackoff.isActive ? provisionError : nil
    }

    mutating func noteProvisionFailure(_ error: any Error, backoff: Duration) {
      provisionError = error
      provisionBackoff.start(for: backoff)
    }

    mutating func clearProvisionFailure() { provisionError = nil }
  }

  private let clientID: String
  private let baseURL: URL
  private let attestation: any AttestationService
  private let store: any AppAttestStore
  private let transport: any HTTPTransport
  /// Refresh this far before expiry so a request never races an expiring
  /// token.
  private let refreshLeeway: TimeInterval = 60

  private var credentials = CredentialState()
  private var pacing = RecoveryPacing()
  /// Pre-issued by the server in register/token responses; single-use.
  private var pendingChallenge: (challenge: Data, expiresAt: ContinuousClock.Instant)?
  private var refreshInFlight: Task<String, Error>?
  private var registrationInFlight: Task<String, Error>?

  private func validToken(leeway: TimeInterval? = nil) -> StoredToken? {
    guard let token = credentials.token,
      token.expiresAt > Date().addingTimeInterval(leeway ?? refreshLeeway)
    else { return nil }
    return token
  }

  // MARK: - Refresh

  private func refresh() async throws -> String {
    let keyID = try await ensureKeyID()
    // A first-run registration supplies the token itself.
    if let token = validToken() { return token.value }
    let token: StoredToken
    do {
      do {
        token = try await mintToken(keyID: keyID)
      } catch AppAttestError.keyInvalidated {
        token = try await recoverFromRejectedAssertion(keyID: keyID)
      }
    } catch {
      // The refresh leeway means the old token may still be valid, so
      // prefer serving it over surfacing a mint failure.
      if let token = validToken(leeway: 0) { return token.value }
      throw error
    }
    credentials.token = token
    credentials.storedTokenSuspect = false
    try? store.setToken(token, for: clientID)
    return token.value
  }

  /// The server returns the same opaque 401 for an expired or raced
  /// challenge as for an invalid key. Retrying with a fresh challenge
  /// settles which one it was; only a second consecutive rejection is
  /// treated as an invalid key.
  private func recoverFromRejectedAssertion(keyID: String) async throws -> StoredToken {
    do {
      return try await mintToken(keyID: keyID)
    } catch AppAttestError.keyInvalidated {
      guard !pacing.keyReplacement.isActive else { throw AppAttestError.keyInvalidated }
      pacing.keyReplacement.start(for: RecoveryPacing.keyReplacementWindow)
      // Register the replacement before discarding the old key. If the
      // registration also fails (the same condition can reject both), the
      // old key remains usable once the condition clears.
      let newKeyID = try await ensureKeyID(replacing: keyID)
      if let registration = validToken(leeway: 0) { return registration }
      return try await mintToken(keyID: newKeyID)
    }
  }

  // MARK: - Key provisioning

  /// Returns the loaded key, or registers a fresh one. Passing `replacing`
  /// skips the caches and forces a replacement for a server-rejected key.
  /// Concurrent registrations coalesce onto one attempt.
  private func ensureKeyID(replacing rejected: String? = nil) async throws -> String {
    if rejected == nil {
      if let keyID = credentials.keyID { return keyID }
      if let stored = try store.keyID(for: clientID) {
        credentials.keyID = stored
        return stored
      }
    }
    if let registrationInFlight { return try await registrationInFlight.value }
    let task = Task { try await createAndRegisterKey() }
    registrationInFlight = task
    defer { if registrationInFlight == task { registrationInFlight = nil } }
    return try await task.value
  }

  private func createAndRegisterKey() async throws -> String {
    guard attestation.isSupported else { throw AppAttestError.unsupported }
    if let pending = pacing.pendingProvisionFailure() { throw pending }
    // Failures up to and including the challenge fetch are cheap and can
    // retry freely; only the attestation and registration steps below
    // record a backoff.
    let newKeyID = try await attestation.generateKey()
    let challenge = try await fetchChallenge(keyID: newKeyID)
    let token: StoredToken
    do {
      token = try await attestAndRegister(keyID: newKeyID, challenge: challenge)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Each attempt past this point costs a rate-limited Apple
      // attestation and a registration-quota slot.
      let backoff: Duration =
        if case AppAttestError.requestFailed(.register, 429, let retryAfter) = error {
          retryAfter.map { .seconds($0) } ?? RecoveryPacing.registrationQuotaFallback
        } else {
          .seconds(60)
        }
      pacing.noteProvisionFailure(error, backoff: backoff)
      throw error
    }
    pacing.clearProvisionFailure()
    // Registration succeeded, so keep the key in memory even if the
    // keychain writes fail. The keychain writes come last because a
    // persisted but unregistered key would be loaded on later launches
    // and skip re-attestation.
    credentials.keyID = newKeyID
    credentials.token = token
    credentials.storedTokenSuspect = false
    try? store.setKeyID(newKeyID, for: clientID)
    try? store.setToken(token, for: clientID)
    return newKeyID
  }

  // MARK: - Wire calls

  /// Attests the key against the challenge and registers it. The response
  /// carries the install's first bearer token.
  private func attestAndRegister(keyID: String, challenge: Data) async throws -> StoredToken {
    let attestationObject = try await attestation.attestKey(
      keyID,
      clientDataHash: Self.registrationClientDataHash(challenge: challenge)
    )
    let (data, status, retryAfter) = try await post(
      path: "v1/oauth/app-attest/register",
      contentType: "application/json",
      body: try JSONEncoder()
        .encode([
          "client_id": clientID,
          "key_id": keyID,
          "attestation_object": attestationObject.base64EncodedString(),
        ])
    )
    // Rejections are deliberately opaque server-side. The key was freshly
    // generated, so "already registered" can't be the cause and there is
    // nothing to retry.
    try Self.requireSuccess(status, endpoint: .register, retryAfter: retryAfter)
    return try ingestToken(from: data)
  }

  /// Exchanges a device assertion over a fresh challenge for a bearer
  /// token.
  private func mintToken(keyID: String) async throws -> StoredToken {
    guard let keyIDBytes = Self.decodeBase64Loose(keyID), keyIDBytes.count == 32 else {
      throw AppAttestError.keyInvalidated
    }
    if pacing.mintRateLimit.isActive {
      throw AppAttestError.requestFailed(endpoint: .token, status: 429, retryAfter: nil)
    }
    let challenge = try await fetchChallenge(keyID: keyID)
    let assertion = try await attestation.generateAssertion(
      keyID,
      clientDataHash: Self.assertionClientDataHash(
        challenge: challenge,
        clientID: clientID,
        keyID: keyIDBytes
      )
    )
    let (data, status, retryAfter) = try await post(
      path: "v1/oauth/token",
      contentType: "application/x-www-form-urlencoded",
      body: Data(
        Self.formEncode([
          "grant_type": "urn:anthropic:params:oauth:grant-type:app-attest",
          "client_id": clientID,
          "key_id": keyID,
          "assertion": assertion.base64EncodedString(),
        ])
        .utf8
      )
    )
    switch status {
    case 401:
      // Deliberately opaque server-side. Could be an unrecognized or
      // revoked key, an expired or raced challenge, or a shared-IP failure
      // budget. The mint rate limit answers 429 and never lands here.
      throw AppAttestError.keyInvalidated
    case 429:
      // Per-device mint limit. Does not indicate a problem with the key.
      pacing.mintRateLimit.start(
        for: retryAfter.map { .seconds($0) } ?? RecoveryPacing.mintRateLimitFallback
      )
      throw AppAttestError.requestFailed(endpoint: .token, status: status, retryAfter: retryAfter)
    default:
      try Self.requireSuccess(status, endpoint: .token, retryAfter: retryAfter)
      return try ingestToken(from: data)
    }
  }

  /// The server re-issues a still-pending challenge with its remaining TTL,
  /// so a challenge abandoned by an earlier attempt can come back nearly
  /// expired. A missing `expires_in` also means nearly expired, because the
  /// wire encoding omits zero values. When the TTL can't cover the signing
  /// round-trip, wait out the remainder and fetch the successor.
  private func fetchChallenge(keyID: String) async throws -> Data {
    // A pre-issued challenge from the last register/token response saves
    // the fetch round-trip. It is single-use, so clear it here even if it
    // turns out too stale to sign.
    if let pending = pendingChallenge {
      pendingChallenge = nil
      if pending.expiresAt - ContinuousClock.now >= .seconds(Self.minimumChallengeTTL) {
        return pending.challenge
      }
    }
    var (challenge, expiresIn) = try await issueChallenge(keyID: keyID)
    if expiresIn ?? 0 < Self.minimumChallengeTTL {
      try await Task.sleep(for: .seconds(max(expiresIn ?? 0, 0) + 1))
      (challenge, expiresIn) = try await issueChallenge(keyID: keyID)
      guard expiresIn ?? 0 >= Self.minimumChallengeTTL else {
        throw AppAttestError.malformedResponse
      }
    }
    return challenge
  }

  /// The TTL a challenge needs to cover its signing round-trip.
  private static let minimumChallengeTTL: Double = 15
  /// Ceiling on wire-supplied durations (`Retry-After`,
  /// `next_challenge_expires_in`, challenge `expires_in`). Values above it
  /// aren't plausible and are treated as absent; this also protects
  /// `Duration.seconds(_:)`, which traps on non-finite or very large
  /// doubles.
  private static let maximumWireDuration: TimeInterval = 86400

  /// Range-checks a wire-supplied duration against `maximumWireDuration`.
  private static func wireDuration(_ raw: TimeInterval?) -> TimeInterval? {
    guard let raw, raw.isFinite, raw >= 0, raw <= maximumWireDuration else { return nil }
    return raw
  }

  /// Parses an OAuth response and keeps the pre-issued challenge it
  /// carries, if any.
  private func ingestToken(from data: Data) throws -> StoredToken {
    let (token, next) = try Self.token(fromOAuthResponse: data)
    if let next {
      pendingChallenge = (next.challenge, .now + .seconds(next.expiresIn))
    }
    return token
  }

  private func issueChallenge(keyID: String) async throws -> (Data, Double?) {
    let (data, status, retryAfter) = try await post(
      path: "v1/oauth/app-attest/challenge",
      contentType: "application/json",
      body: try JSONEncoder().encode(["client_id": clientID, "key_id": keyID])
    )
    try Self.requireSuccess(status, endpoint: .challenge, retryAfter: retryAfter)
    struct ChallengeResponse: Decodable {
      let challenge: String
      let expiresIn: Double?

      enum CodingKeys: String, CodingKey {
        case challenge
        case expiresIn = "expires_in"
      }
    }
    guard
      let response = try? JSONDecoder().decode(ChallengeResponse.self, from: data),
      let challenge = Self.decodeBase64Loose(response.challenge),
      !challenge.isEmpty
    else {
      throw AppAttestError.malformedResponse
    }
    return (challenge, Self.wireDuration(response.expiresIn))
  }

  // MARK: - Bindings

  /// Registration binding: the raw challenge is the client data.
  static func registrationClientDataHash(challenge: Data) -> Data {
    Data(SHA256.hash(data: challenge))
  }

  /// Token-grant binding, version-bearing via the domain prefix. The server
  /// reconstructs these exact bytes from the stored challenge and the
  /// request fields; fixed-length bookends (32-byte challenge and key ID)
  /// make the variable-length client ID unambiguous.
  static func assertionClientDataHash(challenge: Data, clientID: String, keyID: Data) -> Data {
    var hash = SHA256()
    hash.update(data: Data("anthropic-app-attest-token-v1".utf8))
    hash.update(data: challenge)
    hash.update(data: Data(clientID.utf8))
    hash.update(data: keyID)
    return Data(hash.finalize())
  }

  // MARK: - HTTP

  private func post(
    path: String,
    contentType: String,
    body: Data
  ) async throws -> (data: Data, status: Int, retryAfter: TimeInterval?) {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue(contentType, forHTTPHeaderField: "content-type")
    request.setValue(Telemetry.userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = body
    let (data, response) = try await transport.data(for: request)
    let http = response as? HTTPURLResponse
    // Parses only the delta-seconds form; the HTTP-date form is treated
    // as absent. Zero is valid and means retry immediately.
    let retryAfter = Self.wireDuration(
      http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    )
    return (data, http?.statusCode ?? 0, retryAfter)
  }

  /// Shared non-2xx handling; endpoint-specific arms run first at the
  /// call site.
  private static func requireSuccess(
    _ status: Int,
    endpoint: AppAttestError.Endpoint,
    retryAfter: TimeInterval?
  ) throws {
    switch status {
    case 200..<300:
      return
    case 404:
      throw AppAttestError.notYetAvailable
    default:
      throw AppAttestError.requestFailed(
        endpoint: endpoint,
        status: status,
        retryAfter: retryAfter
      )
    }
  }

  /// Percent-encodes everything outside the ASCII unreserved set. Base64
  /// values carry `+` and `=`, which need escaping, and
  /// `CharacterSet.alphanumerics` can't be used here because it also
  /// matches non-ASCII letters.
  static func formEncode(_ fields: [String: String]) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    return
      fields
      .sorted { $0.key < $1.key }
      .map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
      }
      .joined(separator: "&")
  }

  /// Both OAuth-shaped responses (register and token) carry
  /// `access_token` + `expires_in`. The wire encoding omits zero values,
  /// so a token without an `expires_in` is already expired and the
  /// response is treated as malformed.
  private static func token(
    fromOAuthResponse data: Data
  ) throws -> (StoredToken, (challenge: Data, expiresIn: TimeInterval)?) {
    struct OAuthTokenResponse: Decodable {
      let accessToken: String
      let expiresIn: Double?
      let nextChallenge: String?
      let nextChallengeExpiresIn: Double?

      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case nextChallenge = "next_challenge"
        case nextChallengeExpiresIn = "next_challenge_expires_in"
      }
    }
    guard
      let response = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data),
      !response.accessToken.isEmpty,
      let expiresIn = response.expiresIn, expiresIn > 0
    else {
      throw AppAttestError.malformedResponse
    }
    let token = StoredToken(
      value: response.accessToken,
      expiresAt: Date().addingTimeInterval(expiresIn)
    )
    // These fields are optional; the server omits them when it has no
    // pre-issued challenge to offer.
    var next: (challenge: Data, expiresIn: TimeInterval)?
    if let encoded = response.nextChallenge,
      let challenge = Self.decodeBase64Loose(encoded), !challenge.isEmpty,
      let ttl = wireDuration(response.nextChallengeExpiresIn), ttl > 0
    {
      next = (challenge, ttl)
    }
    return (token, next)
  }

  /// Accepts url-safe or standard alphabets, padded or unpadded. Apple's
  /// tooling emits standard base64; the server emits either.
  static func decodeBase64Loose(_ string: String) -> Data? {
    var normalized =
      string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    if normalized.count % 4 != 0 {
      normalized += String(repeating: "=", count: 4 - normalized.count % 4)
    }
    return Data(base64Encoded: normalized)
  }
}

enum AppAttestError: LocalizedError, Sendable, Equatable {
  enum Endpoint: String, Sendable {
    case challenge
    case register
    case token
  }

  /// `DCAppAttestService.isSupported == false`.
  case unsupported
  /// The token endpoint rejected the assertion (an opaque 401) or the key
  /// ID is unusable. Recoverable by re-attesting, rate-limited by the
  /// key-replacement cooldown.
  case keyInvalidated
  /// The endpoints are not deployed on this host.
  case notYetAvailable
  /// The client ID is already in use against a different base URL.
  case conflictingBaseURL
  /// A wire call failed with a non-recoverable status. `retryAfter` is the
  /// server's `Retry-After` in seconds, when it sent one.
  case requestFailed(endpoint: Endpoint, status: Int, retryAfter: TimeInterval?)
  /// A 2xx response body did not carry the expected fields.
  case malformedResponse

  var errorDescription: String? {
    switch self {
    case .unsupported:
      "App Attest is not supported on this device or simulator."
    case .keyInvalidated:
      "Device attestation is no longer valid. The app must re-attest."
    case .notYetAvailable:
      "App Attest authentication is not available on this host."
    case .conflictingBaseURL:
      "This client ID is already attesting against a different base URL."
    case .requestFailed(let endpoint, let status, _):
      "App Attest \(endpoint.rawValue) request failed (HTTP \(status))."
    case .malformedResponse:
      "App Attest service returned an unexpected response."
    }
  }
}
