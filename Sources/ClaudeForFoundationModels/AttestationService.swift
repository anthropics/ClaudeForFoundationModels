// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Seam over `DCAppAttestService` so attestation flows are testable and the
/// `isSupported == false` path (simulators, hardware without Secure Enclave)
/// is mockable.
protocol AttestationService: Sendable {
  var isSupported: Bool { get }
  /// Generates a new key pair in the Secure Enclave; returns an opaque key ID.
  func generateKey() async throws -> String
  /// Runs once per key and includes an Apple round-trip of roughly 3–8
  /// seconds. Produces a CBOR attestation object signed by Apple vouching
  /// for the key.
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
  /// Runs locally and quickly on each request. Signs `clientDataHash`
  /// with the attested key; the signature includes a monotonic counter for
  /// replay protection.
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

#if canImport(DeviceCheck)
struct DeviceAttestationService: AttestationService {
  init() {}
  var isSupported: Bool { DCAppAttestService.shared.isSupported }
  func generateKey() async throws -> String {
    try await DCAppAttestService.shared.generateKey()
  }
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
    try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
  }
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    do {
      return try await DCAppAttestService.shared.generateAssertion(
        keyID,
        clientDataHash: clientDataHash
      )
    } catch let error as DCError where error.code == .invalidKey {
      // The Secure Enclave no longer holds this key. A device erase
      // followed by a same-device restore brings back the keychain entry
      // but not the key itself, so a new attestation is required.
      throw AppAttestError.keyInvalidated
    }
  }
}
#endif
