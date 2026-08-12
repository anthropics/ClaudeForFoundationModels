// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels
import Synchronization

/// Executes generation requests against the Messages API.
///
/// One executor is created per unique ``Configuration`` and reused. Heavy
/// resources (the HTTP client) live here, not on ``ClaudeLanguageModel``.
public struct ClaudeExecutor: LanguageModelExecutor {
  public typealias Model = ClaudeLanguageModel

  public struct Configuration: Hashable, Sendable {
    public let model: ClaudeModel
    public let baseURL: URL
    public let authMode: AuthMode
    public let serverTools: Set<ClaudeServerTool>
    public let timeout: TimeInterval
    public let fixedEffort: ClaudeModel.Effort?

    public init(
      model: ClaudeModel,
      baseURL: URL,
      authMode: AuthMode,
      serverTools: Set<ClaudeServerTool> = [],
      timeout: TimeInterval,
      fixedEffort: ClaudeModel.Effort? = nil
    ) {
      self.model = model
      self.baseURL = baseURL
      self.authMode = authMode
      self.serverTools = serverTools
      self.timeout = timeout
      self.fixedEffort = fixedEffort
    }
  }

  private let configuration: Configuration
  private let client: ClaudeClient
  private let attestSession: AppAttestSession?

  public init(configuration: Configuration) throws {
    let transport = Self.makeTransport(timeout: configuration.timeout)
    self.init(
      configuration: configuration,
      transport: transport,
      attestSession: try Self.makeAttestSession(configuration, transport: transport)
    )
  }

  /// Builds a transport honoring the configured request timeout.
  static func makeTransport(timeout: TimeInterval) -> URLSessionTransport {
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = timeout
    return URLSessionTransport(session: URLSession(configuration: sessionConfig))
  }

  /// Injects the transport so the executor can be exercised without a network.
  /// The wire-auth mapping and client construction still run here.
  init(
    configuration: Configuration,
    transport: any HTTPTransport,
    attestSession: AppAttestSession? = nil
  ) {
    self.configuration = configuration
    self.attestSession = attestSession

    let auth: ClaudeAPI.Configuration.Auth
    switch configuration.authMode {
    case .apiKey(let key) where !key.isEmpty:
      auth = .apiKey(key)
    case .apiKey, .proxied, .appAttest:
      auth = .none
    }
    self.client = ClaudeClient(
      configuration: .init(auth: auth, baseURL: configuration.baseURL),
      transport: transport
    )
  }

  /// Builds the transport only when the session isn't already cached.
  static func makeAttestSession(for configuration: Configuration) throws -> AppAttestSession? {
    try makeAttestSession(
      configuration,
      transport: makeTransport(timeout: configuration.timeout)
    )
  }

  static func makeAttestSession(
    _ configuration: Configuration,
    transport: @autoclosure @escaping () -> any HTTPTransport
  ) throws -> AppAttestSession? {
    guard case .appAttest(let clientID) = configuration.authMode else { return nil }
    #if canImport(DeviceCheck)
    do {
      return try AppAttestSession.shared(clientID: clientID, baseURL: configuration.baseURL) {
        AppAttestSession(
          clientID: clientID,
          baseURL: configuration.baseURL,
          attestation: DeviceAttestationService(),
          transport: transport()
        )
      }
    } catch let error as AppAttestError {
      // Map to a public error type before it escapes the public init.
      throw ErrorMapper.map(error)
    }
    #else
    return nil
    #endif
  }

  public func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: ClaudeLanguageModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    do {
      let built = try RequestBuilder.build(
        from: request,
        model: configuration.model,
        fixedEffort: configuration.fixedEffort,
        serverTools: configuration.serverTools
      )
      var translator = EventTranslator()
      var request = built.request
      var sentCount = 0
      // The API pauses a long server-tool loop (`pause_turn`) and resumes it
      // when the content so far is sent back. A pause that delivered nothing
      // would be re-sent unchanged, so it ends the turn instead.
      while true {
        let stopReason = try await send(request, translating: &translator, into: channel)
        let content = translator.continuationContent
        guard stopReason == .pauseTurn, content.count > sentCount else { return }
        try Task.checkCancellation()
        sentCount = content.count
        request = built.request
        request.messages.append(.init(role: .assistant, content: content))
      }
    } catch {
      throw ErrorMapper.map(error, usesAppAttest: attestSession != nil)
    }
  }

  public func prewarm(model: ClaudeLanguageModel, transcript: Transcript) {
    // Attesting at launch keeps the multi-second first-run Apple
    // round-trip off the user's first prompt. Errors are dropped because
    // the prewarm contract has no way to report them.
    if let attestSession {
      Task { try? await attestSession.attestIfNeeded() }
    }
  }

  /// Sends one request of a turn and translates its response into the
  /// turn's translator, refreshing a rejected App Attest token once.
  private func send(
    _ request: MessagesRequest,
    translating translator: inout EventTranslator,
    into channel: LanguageModelExecutorGenerationChannel
  ) async throws -> StopReason? {
    let channelWritten = Mutex(false)
    let (headers, bearer) = try await authContext()
    do {
      return try await translator.translate(
        client.stream(request, headers: headers),
        into: channel,
        onFirstChannelWrite: { @Sendable in channelWritten.withLock { $0 = true } }
      )
    } catch let error as APIError where error.kind == .authentication && attestSession != nil {
      // The token raced expiration or was revoked between fetch and
      // validation. Invalidate it either way, so the next request doesn't
      // reuse it. Retrying is only safe while this response has written
      // nothing to the channel (a retry would duplicate the content), and
      // only once: a second rejection means the key or registration is
      // actually bad.
      await attestSession?.invalidateToken(usedToken: bearer)
      guard !channelWritten.withLock({ $0 }) else { throw error }
      let (retryHeaders, retryBearer) = try await authContext()
      do {
        return try await translator.translate(
          client.stream(request, headers: retryHeaders),
          into: channel
        )
      } catch let error as APIError where error.kind == .authentication {
        await attestSession?.invalidateToken(usedToken: retryBearer)
        throw error
      }
    }
  }

  /// Per-request headers merged over `ClaudeClient`'s defaults, and the
  /// bearer value those headers carry under App Attest (nil otherwise).
  /// `.apiKey` sets `x-api-key` via `ClaudeClient`, so this only enforces
  /// that a key was actually provided; `.proxied` forwards the developer's
  /// proxy headers.
  private func authContext() async throws -> (headers: [String: String], bearer: String?) {
    switch configuration.authMode {
    case .apiKey(let key):
      guard !key.isEmpty else { throw ClaudeError.missingCredential }
      return ([:], nil)
    case .proxied(let headers):
      return (headers, nil)
    case .appAttest:
      guard let attestSession else { throw AppAttestError.unsupported }
      let token = try await attestSession.currentToken()
      return (["Authorization": "Bearer \(token)"], token)
    }
  }
}
