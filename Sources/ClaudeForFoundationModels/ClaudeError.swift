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

  public var errorDescription: String? {
    switch self {
    case .missingCredential:
      "No Claude credential. Provide an API key."
    }
  }
}
