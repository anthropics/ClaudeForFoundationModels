// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Maps Messages API failures onto the framework's typed errors so app
/// developers can pattern-match on well-known cases.
enum ErrorMapper {
  /// `usesAppAttest` disambiguates authentication failures: under App
  /// Attest a credential existed and the server rejected it, so "provide an
  /// API key" would be wrong guidance.
  static func map(_ error: any Error, usesAppAttest: Bool) -> any Error {
    if let api = error as? APIError {
      return map(api, usesAppAttest: usesAppAttest)
    }
    if let attest = error as? AppAttestError {
      return map(attest)
    }
    #if canImport(DeviceCheck)
    if error is DCError {
      // Apple's attestation service failed (feature unsupported, server
      // unavailable); no credential was produced.
      return ClaudeError.attestationFailed
    }
    #endif
    if error is KeychainError {
      // Keychain reads can fail before first unlock, leaving the
      // credential temporarily unreachable. Surface the typed attestation
      // failure rather than an internal error type.
      return ClaudeError.attestationFailed
    }
    if let url = error as? URLError, url.code == .timedOut {
      return LanguageModelError.timeout(.init(debugDescription: url.localizedDescription))
    }
    if let image = error as? ClaudeImage.Error {
      return LanguageModelError.unsupportedTranscriptContent(
        .init(
          unsupportedContent: [],
          debugDescription: image.errorDescription ?? "Image could not be prepared for upload."
        )
      )
    }
    return error
  }

  /// `AppAttestError` is internal; what callers can act on is the split
  /// between "this device can never attest" and "attestation didn't yield a
  /// credential this time".
  static func map(_ error: AppAttestError) -> ClaudeError {
    switch error {
    case .unsupported:
      .attestationUnsupported
    case .keyInvalidated, .notYetAvailable, .conflictingBaseURL, .requestFailed,
      .malformedResponse:
      .attestationFailed
    }
  }

  static func map(_ error: APIError, usesAppAttest: Bool) -> any Error {
    let detail = error.requestID.map { "\(error.message) (request_id: \($0))" } ?? error.message

    switch error.kind {
    case .rateLimit, .overloaded:
      // The API doesn't say when capacity returns, so no reset date is
      // fabricated — callers pick their own backoff.
      return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: detail))
    case .requestTooLarge:
      // The API reports neither the window nor the prompt's token count.
      return LanguageModelError.contextSizeExceeded(
        .init(contextSize: 0, tokenCount: 0, debugDescription: detail)
      )
    case .invalidRequest where error.message.lowercased().contains("context"):
      return LanguageModelError.contextSizeExceeded(
        .init(contextSize: 0, tokenCount: 0, debugDescription: detail)
      )
    case .authentication:
      return usesAppAttest ? ClaudeError.attestationFailed : ClaudeError.missingCredential
    case .permission, .api, .invalidRequest, .notFound, .other:
      // No honest framework-error equivalent — surface the API error itself.
      // `.permission` means the credential exists but isn't allowed here;
      // calling that a missing credential would send users to key entry.
      return error
    }
  }
}
