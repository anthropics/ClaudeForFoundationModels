// Copyright 2026 Anthropic PBC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import FoundationModels

/// Claude as a Foundation Models server-side language model.
///
/// ```swift
/// let model = ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey("..."))
/// let session = LanguageModelSession(model: model)
/// let response = try await session.respond(to: "Plan a 4-day trip to Buenos Aires")
/// ```
public struct ClaudeLanguageModel: Sendable {
  public let model: ClaudeModel
  public let baseURL: URL
  public let timeout: TimeInterval
  public let serverTools: Set<ClaudeServerTool>
  public let fixedEffort: ClaudeModel.Effort?
  public let fallbacks: ClaudeFallbacks
  public let userProfileID: String?
  let authMode: AuthMode

  /// - Parameters:
  ///   - name: Claude model identifier. Use a constant (`.sonnet5`, `.opus5`,
  ///     `.haiku4_5`), or construct a ``ClaudeModel`` with explicit capabilities
  ///     for IDs not yet compiled in.
  ///   - auth: Credential mode. `.apiKey` for prototyping; `.proxied` with a
  ///     custom `baseURL` to route through a developer-run relay that adds
  ///     credentials server-side.
  ///   - userProfileID: The user profile to attribute every request to, when
  ///     the app acts on behalf of someone other than your organization. This
  ///     is the ID of a profile you created with the API's user profiles
  ///     endpoints, and it starts with `uprof_`. It's sent in the
  ///     `anthropic-user-profile-id` header. The API checks it, so a malformed
  ///     or unknown ID fails the request. `nil` sends no profile.
  ///   - fixedEffort: Claude effort level, sent as `output_config.effort` on
  ///     every request. Fixed for the life of the model value: it takes
  ///     precedence over the framework's per-request reasoning hint, and is
  ///     the only way to request ``ClaudeModel/Effort/xhigh`` or
  ///     ``ClaudeModel/Effort/max``, which the framework's reasoning levels
  ///     don't express. Must be a level the model accepts
  ///     (``ClaudeModel/Capabilities/effortLevels``) — checked at
  ///     initialization. Each of the `fallbacks` gets the closest level it
  ///     accepts.
  ///   - fallbacks: Substitute models the API tries, in order, when `name`
  ///     declines a request for policy reasons. See ``ClaudeFallbacks``.
  ///     A fallback can narrow what the model offers. Images and guided
  ///     generation need every model in the chain to support them, and
  ///     sampling parameters are sent only when every model accepts them.
  ///   - serverTools: Tools that execute on Anthropic's infrastructure
  ///     (web search, code execution). Distinct from the framework's
  ///     `tools:` array, which the framework invokes client-side.
  ///   - baseURL: API endpoint. Override to point at a developer-run proxy
  ///     that adds authentication server-side (use with ``AuthMode/proxied``).
  ///     Credentials are only ever sent to this scheme, host, and port: a
  ///     redirect elsewhere fails the request instead of being followed.
  public init(
    name: ClaudeModel,
    auth: AuthMode,
    userProfileID: String? = nil,
    fixedEffort: ClaudeModel.Effort? = nil,
    fallbacks: ClaudeFallbacks = [],
    serverTools: Set<ClaudeServerTool> = [],
    baseURL: URL = ClaudeLanguageModel.defaultBaseURL,
    timeout: TimeInterval = 60
  ) {
    if let fixedEffort {
      precondition(
        name.capabilities.effortLevels.contains(fixedEffort),
        """
        \(name.id) does not accept effort '\(fixedEffort.rawValue)' — it accepts: \
        \(name.capabilities.effortLevels.map(\.rawValue).sorted())
        """
      )
    }
    self.model = name
    self.authMode = auth
    self.fixedEffort = fixedEffort
    self.fallbacks = fallbacks
    self.userProfileID = userProfileID
    self.serverTools = serverTools
    self.baseURL = baseURL
    self.timeout = timeout
  }

  /// Idempotent. Under ``AuthMode/appAttest(clientID:)``, performs the
  /// first-run device attestation so its multi-second cost and any failure
  /// surface here instead of on the first request. A no-op for every other
  /// mode.
  public func authenticateIfNeeded() async throws {
    guard case .appAttest = authMode else { return }
    let configuration = executorConfiguration
    do {
      guard let session = try ClaudeExecutor.makeAttestSession(for: configuration)
      else { throw ClaudeError.attestationUnsupported }
      try await session.attestIfNeeded()
    } catch {
      throw ErrorMapper.map(error, usesAppAttest: true)
    }
  }

  public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
}

extension ClaudeLanguageModel: LanguageModel {
  public typealias Executor = ClaudeExecutor

  /// Derived from the model's ``ClaudeModel/Capabilities`` so the framework
  /// only routes work the bridge will actually send. Images and guided
  /// generation are contracts, so they need every model in
  /// ``fallbacks`` to support them as well. Reasoning is a hint, so it
  /// follows the requested model alone.
  public var capabilities: LanguageModelCapabilities {
    let chain = [model] + fallbacks.knownModels
    var capabilities: [LanguageModelCapabilities.Capability] = [.toolCalling]
    if chain.allSatisfy(\.capabilities.imageInput) { capabilities.append(.vision) }
    if model.capabilities.adaptiveThinking { capabilities.append(.reasoning) }
    if chain.allSatisfy(\.capabilities.structuredOutput) {
      capabilities.append(.guidedGeneration)
    }
    return LanguageModelCapabilities(capabilities)
  }

  public var executorConfiguration: ClaudeExecutor.Configuration {
    .init(
      model: model,
      baseURL: baseURL,
      authMode: authMode,
      serverTools: serverTools,
      timeout: timeout,
      fixedEffort: fixedEffort,
      fallbacks: fallbacks,
      userProfileID: userProfileID
    )
  }
}
