// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

#if canImport(DeviceCheck)
import DeviceCheck
#endif

@Suite struct ClaudeLanguageModelTests {
  @Test func `advertised capabilities follow the model's declared capabilities`() {
    let full = ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey("k"))
    #expect(full.capabilities.contains(.toolCalling))
    #expect(full.capabilities.contains(.vision))
    #expect(full.capabilities.contains(.reasoning))
    #expect(full.capabilities.contains(.guidedGeneration))
  }

  @Test func `a restricted model doesn't advertise what the bridge won't send`() {
    let limited = ClaudeLanguageModel(
      name: ClaudeModel(
        id: "claude-test",
        capabilities: .init(adaptiveThinking: false, structuredOutput: false, imageInput: false)
      ),
      auth: .apiKey("k")
    )
    #expect(limited.capabilities.contains(.toolCalling))
    #expect(!limited.capabilities.contains(.vision))
    #expect(!limited.capabilities.contains(.reasoning))
    #expect(!limited.capabilities.contains(.guidedGeneration))
  }

  // Images and a schema are contracts, so every model that may serve the
  // request has to take them. Reasoning is a hint, so it follows the model.
  @Test func `fallbacks narrow the contracts but not the hints`() {
    let plain = ClaudeModel(id: "claude-plain", capabilities: .init())
    let model = ClaudeLanguageModel(name: .opus5, auth: .apiKey("k"), fallbacks: [plain])
    #expect(model.capabilities.contains(.toolCalling))
    #expect(model.capabilities.contains(.reasoning))
    #expect(!model.capabilities.contains(.vision))
    #expect(!model.capabilities.contains(.guidedGeneration))
    #expect(model.executorConfiguration.fallbacks == [plain])

    // The model's own configuration names no model to check.
    let serverDefault = ClaudeLanguageModel(
      name: .opus5,
      auth: .apiKey("k"),
      fallbacks: .serverDefault
    )
    #expect(serverDefault.capabilities.contains(.vision))
    #expect(serverDefault.capabilities.contains(.guidedGeneration))
    #expect(serverDefault.executorConfiguration.fallbacks == .serverDefault)
  }

  // Each fallback gets the closest effort level it accepts, so the fixed
  // effort is checked against the requested model alone.
  @Test func `a fixed effort is checked against the model, not its fallbacks`() {
    let plain = ClaudeModel(id: "claude-plain", capabilities: .init())
    let model = ClaudeLanguageModel(
      name: .opus5,
      auth: .apiKey("k"),
      fixedEffort: .xhigh,
      fallbacks: [plain]
    )
    #expect(model.executorConfiguration.fixedEffort == .xhigh)
  }

  @Test func `a fixed effort flows into the executor configuration`() {
    let model = ClaudeLanguageModel(name: .opus4_8, auth: .apiKey("k"), fixedEffort: .max)
    #expect(model.executorConfiguration.fixedEffort == .max)
  }
  @Test func `authenticateIfNeeded is a no-op for api key auth`() async throws {
    let model = ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey("k"))
    try await model.authenticateIfNeeded()
  }

  #if canImport(DeviceCheck)
  // Runs only where App Attest is unavailable; on capable hardware this
  // would attempt a live Apple attestation.
  @Test(.enabled(if: !DCAppAttestService.shared.isSupported))
  func `authenticateIfNeeded surfaces attestation failure as a public error`() async {
    let model = ClaudeLanguageModel(
      name: .sonnet4_6,
      auth: .appAttest(clientID: "clid_authenticate_\(UUID().uuidString)")
    )
    do {
      try await model.authenticateIfNeeded()
      Issue.record("expected authenticateIfNeeded to throw off-device")
    } catch {
      #expect(error is ClaudeError)
    }
  }
  #endif

}
