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
