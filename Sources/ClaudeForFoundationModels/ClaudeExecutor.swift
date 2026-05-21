// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

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

  public init(configuration: Configuration) throws {
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = configuration.timeout
    self.init(
      configuration: configuration,
      transport: URLSessionTransport(session: URLSession(configuration: sessionConfig))
    )
  }

  /// Injects the transport so the executor can be exercised without a network.
  /// The wire-auth mapping and client construction still run here.
  init(configuration: Configuration, transport: any HTTPTransport) {
    self.configuration = configuration

    let auth: ClaudeAPI.Configuration.Auth
    switch configuration.authMode {
    case .apiKey(let key) where !key.isEmpty:
      auth = .apiKey(key)
    case .apiKey, .proxied:
      auth = .none
    }
    self.client = ClaudeClient(
      configuration: .init(auth: auth, baseURL: configuration.baseURL),
      transport: transport
    )
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
      try await stream(built.request, with: EventTranslator(), into: channel)
    } catch {
      throw ErrorMapper.map(error)
    }
  }

  private func stream(
    _ request: MessagesRequest,
    with translator: EventTranslator,
    into channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    let headers = try await authHeaders()
    try await translator.translate(client.stream(request, headers: headers), into: channel)
  }

  /// Per-request headers merged over `ClaudeClient`'s defaults. `.apiKey` sets
  /// `x-api-key` via `ClaudeClient`, so this only enforces that a key was
  /// actually provided; `.proxied` forwards the developer's proxy headers.
  private func authHeaders() async throws -> [String: String] {
    switch configuration.authMode {
    case .apiKey(let key):
      guard !key.isEmpty else { throw ClaudeError.missingCredential }
      return [:]
    case .proxied(let headers):
      return headers
    }
  }
}
