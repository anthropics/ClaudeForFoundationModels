// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeForFoundationModels

/// Keychain access requires an application-identifier entitlement that the
/// SwiftPM `xctest` runner doesn't carry — every call returns
/// `errSecMissingEntitlement` (-34018) there. The probe gates the suite so
/// it runs only where it can (a host app, a signed test bundle).
private let keychainAvailable: Bool = {
  let probe = KeychainAppAttestStore(service: "com.anthropic.cffm.tests.probe")
  do {
    try probe.setKeyID("probe", for: "probe")
    try probe.clear(for: "probe")
    return true
  } catch {
    return false
  }
}()

@Suite(.enabled(if: keychainAvailable))
struct AppAttestStoreTests {
  /// A throwaway service string per test instance keeps the suite from
  /// touching the production namespace and makes leftovers from a crashed
  /// run harmless.
  private let store = KeychainAppAttestStore(
    service: "com.anthropic.claude-foundation-models.tests.\(UUID().uuidString)"
  )
  private let clientID = "clid_test"

  @Test func `key id round-trips and clears`() throws {
    defer { try? store.clear(for: clientID) }
    #expect(try store.keyID(for: clientID) == nil)

    try store.setKeyID("key-1", for: clientID)
    #expect(try store.keyID(for: clientID) == "key-1")

    try store.setKeyID("key-2", for: clientID)
    #expect(try store.keyID(for: clientID) == "key-2")

    try store.clear(for: clientID)
    #expect(try store.keyID(for: clientID) == nil)
  }

  @Test func `token round-trips and deletes`() throws {
    defer { try? store.clear(for: clientID) }
    #expect(try store.token(for: clientID) == nil)

    let token = StoredToken(value: "tok-1", expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
    try store.setToken(token, for: clientID)
    #expect(try store.token(for: clientID) == token)

    try store.deleteToken(for: clientID)
    #expect(try store.token(for: clientID) == nil)
    try store.deleteToken(for: clientID)  // idempotent
  }

  @Test func `client ids are isolated`() throws {
    defer {
      try? store.clear(for: "a")
      try? store.clear(for: "b")
    }
    try store.setKeyID("ka", for: "a")
    try store.setKeyID("kb", for: "b")
    #expect(try store.keyID(for: "a") == "ka")
    #expect(try store.keyID(for: "b") == "kb")
    try store.clear(for: "a")
    #expect(try store.keyID(for: "a") == nil)
    #expect(try store.keyID(for: "b") == "kb")
  }
}
