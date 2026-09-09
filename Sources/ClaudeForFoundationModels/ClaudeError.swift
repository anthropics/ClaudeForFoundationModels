// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Errors surfaced by the Claude provider that don't map onto a
/// ``LanguageModelError`` case. App developers can pattern-match on these to
/// drive product flows (key entry).
public enum ClaudeError: LocalizedError, Sendable {
  /// No usable credential. Provide an API key via ``AuthMode/apiKey(_:)``,
  /// or, when using ``AuthMode/proxied(headers:)``, check that the proxy
  /// supplies authentication.
  case missingCredential
  /// App Attest can't run on this hardware (simulators, devices without a
  /// Secure Enclave). Use ``AuthMode/apiKey(_:)`` for development, or
  /// ``AuthMode/proxied(headers:)``.
  case attestationUnsupported
  /// The device supports App Attest but no credential could be obtained.
  /// Causes include the server rejecting the attestation or assertion, an
  /// unusable response, an unreachable credential store, and a client ID
  /// already in use against a different base URL.
  case attestationFailed
  /// The request requires a tool call (tool-calling mode `.required`) and the
  /// model doesn't accept that — its ``ClaudeModel/Capabilities/forcedToolUse``
  /// is `false`. Nothing was sent. Use the default tool-calling mode, or a
  /// model that supports requiring a tool call.
  case forcedToolUseUnsupported

  public var errorDescription: String? {
    switch self {
    case .missingCredential:
      "No Claude credential. Provide an API key."
    case .attestationUnsupported:
      "App Attest is not supported on this device or simulator."
    case .attestationFailed:
      "App attestation failed to produce a credential."
    case .forcedToolUseUnsupported:
      "This Claude model can't be required to call a tool. Use the default tool-calling mode."
    }
  }
}
