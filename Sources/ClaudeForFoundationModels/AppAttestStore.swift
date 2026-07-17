// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Persistence for the App Attest key ID and the most recent bearer token.
/// Both are device-bound: the key ID names a Secure Enclave key that doesn't
/// migrate, and the token is derived from it. A conforming store must not
/// sync or back up either value off-device.
protocol AppAttestStore: Sendable {
  func keyID(for clientID: String) throws -> String?
  func setKeyID(_ keyID: String, for clientID: String) throws
  func token(for clientID: String) throws -> StoredToken?
  func setToken(_ token: StoredToken, for clientID: String) throws
  func deleteToken(for clientID: String) throws
}

struct StoredToken: Codable, Sendable, Equatable {
  let value: String
  let expiresAt: Date
}

/// Keychain-backed store. Items are `kSecClassGenericPassword`,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, namespaced by a service
/// string and keyed on `clientID#<slot>` so multiple registrations in one app
/// don't collide.
struct KeychainAppAttestStore: AppAttestStore {
  static let defaultService = "com.anthropic.claude-foundation-models.app-attest"

  private let service: String
  private let accessGroup: String?

  /// - Parameters:
  ///   - service: `kSecAttrService`; namespaces this store's items away
  ///     from other keychain entries.
  ///   - accessGroup: `kSecAttrAccessGroup`. Sharing the store across
  ///     processes is unsupported: assertion ordering is coordinated only
  ///     within one process, and concurrent processes over one key race the
  ///     server's single-use challenge and strictly-increasing sign count.
  init(service: String = Self.defaultService, accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  func keyID(for clientID: String) throws -> String? {
    guard let data = try read(account(clientID, .keyID)) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  func setKeyID(_ keyID: String, for clientID: String) throws {
    try upsert(Data(keyID.utf8), at: account(clientID, .keyID))
  }

  func token(for clientID: String) throws -> StoredToken? {
    guard let data = try read(account(clientID, .token)) else { return nil }
    return try JSONDecoder().decode(StoredToken.self, from: data)
  }

  func setToken(_ token: StoredToken, for clientID: String) throws {
    try upsert(JSONEncoder().encode(token), at: account(clientID, .token))
  }

  func deleteToken(for clientID: String) throws {
    try delete(account(clientID, .token))
  }

  func clear(for clientID: String) throws {
    try delete(account(clientID, .keyID))
    try delete(account(clientID, .token))
  }

  // MARK: - Keychain plumbing

  private enum Slot: String {
    case keyID = "key-id"
    case token
  }

  private func account(_ clientID: String, _ slot: Slot) -> String {
    "\(clientID)#\(slot.rawValue)"
  }

  private func query(_ account: String) -> [CFString: Any] {
    var q: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      // On macOS the file-based login keychain ignores accessibility and
      // access-group attributes and is included in backups; the data
      // protection keychain honors them everywhere.
      kSecUseDataProtectionKeychain: true,
    ]
    if let accessGroup { q[kSecAttrAccessGroup] = accessGroup }
    return q
  }

  private func read(_ account: String) throws -> Data? {
    var q = query(account)
    q[kSecReturnData] = true
    q[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    switch status {
    case errSecSuccess: return result as? Data
    case errSecItemNotFound: return nil
    default: throw KeychainError(status: status)
    }
  }

  private func upsert(_ data: Data, at account: String) throws {
    let q = query(account)
    let attrs: [CFString: Any] = [
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var add = q
      add.merge(attrs) { _, new in new }
      switch SecItemAdd(add as CFDictionary, nil) {
      case errSecSuccess:
        return
      case errSecDuplicateItem:
        // Update-then-add is not atomic; a concurrent writer can insert
        // between the two calls — update the winner's row.
        let retry = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        guard retry == errSecSuccess else { throw KeychainError(status: retry) }
      case let addStatus:
        throw KeychainError(status: addStatus)
      }
    default:
      throw KeychainError(status: status)
    }
  }

  private func delete(_ account: String) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }
}

struct KeychainError: LocalizedError, Sendable {
  let status: OSStatus

  var errorDescription: String? {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return "Keychain error: \(message)"
  }
}
