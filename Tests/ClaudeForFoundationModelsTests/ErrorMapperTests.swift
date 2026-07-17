// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

@Suite struct ErrorMapperTests {
  private func mapped(
    _ kind: APIError.Kind,
    _ message: String = "boom",
    requestID: String? = nil
  )
    -> any Error
  {
    ErrorMapper.map(
      APIError(kind: kind, message: message, requestID: requestID),
      usesAppAttest: false
    )
  }

  @Test func `rate limit becomes rateLimited with no reset date`() {
    guard case LanguageModelError.rateLimited(let payload) = mapped(.rateLimit, "slow down") else {
      Issue.record("expected rateLimited")
      return
    }
    #expect(payload.resetDate == nil)
    #expect(payload.debugDescription.contains("slow down"))
  }

  @Test func `overloaded becomes rateLimited with no fabricated reset date`() {
    guard case LanguageModelError.rateLimited(let payload) = mapped(.overloaded) else {
      Issue.record("expected rateLimited")
      return
    }
    // The API doesn't say when capacity returns, so neither do we.
    #expect(payload.resetDate == nil)
  }

  @Test func `request too large becomes contextSizeExceeded`() {
    guard case LanguageModelError.contextSizeExceeded = mapped(.requestTooLarge) else {
      Issue.record("expected contextSizeExceeded")
      return
    }
  }

  @Test func `invalid request mentioning context becomes contextSizeExceeded`() {
    guard
      case LanguageModelError.contextSizeExceeded = mapped(
        .invalidRequest,
        "Context length exceeded"
      )
    else {
      Issue.record("expected contextSizeExceeded")
      return
    }
  }

  @Test func `plain invalid request passes through unchanged`() {
    #expect((mapped(.invalidRequest, "missing field") as? APIError)?.kind == .invalidRequest)
  }

  @Test func `not found passes through unchanged`() {
    #expect((mapped(.notFound) as? APIError)?.kind == .notFound)
  }

  @Test func `authentication becomes missingCredential`() {
    guard case ClaudeError.missingCredential = mapped(.authentication) else {
      Issue.record("expected missingCredential for auth")
      return
    }
  }

  @Test func `permission passes through unchanged`() {
    // A valid credential without access is not a missing credential — keep
    // the API's own message so the developer sees what was denied.
    #expect((mapped(.permission) as? APIError)?.kind == .permission)
  }

  @Test func `generic api error passes through unchanged`() {
    #expect((mapped(.api, "internal error") as? APIError)?.kind == .api)
  }

  @Test func `request id is folded into the debug description`() {
    guard
      case LanguageModelError.rateLimited(let payload) = mapped(
        .rateLimit,
        "slow",
        requestID: "req_9"
      )
    else {
      Issue.record("expected rateLimited")
      return
    }
    #expect(payload.debugDescription.contains("req_9"))
    #expect(payload.debugDescription.contains("slow"))
  }

  @Test func `URLError timeout becomes a LanguageModelError timeout`() {
    guard
      case LanguageModelError.timeout = ErrorMapper.map(URLError(.timedOut), usesAppAttest: false)
    else {
      Issue.record("expected timeout")
      return
    }
  }

  @Test func `a non-timeout URLError passes through unchanged`() {
    let original = URLError(.notConnectedToInternet)
    #expect(
      (ErrorMapper.map(original, usesAppAttest: false) as? URLError)?.code
        == .notConnectedToInternet
    )
  }

  @Test func `an unrecognized API error kind passes through as the APIError`() {
    #expect((mapped(.other, "novel failure") as? APIError)?.kind == .other)
  }

  @Test func `image preparation failures map to unsupportedTranscriptContent`() {
    guard
      case LanguageModelError.unsupportedTranscriptContent(let payload) = ErrorMapper.map(
        ClaudeImage.Error.tooLarge(byteCount: 99),
        usesAppAttest: false
      )
    else {
      Issue.record("expected unsupportedTranscriptContent")
      return
    }
    #expect(payload.debugDescription.contains("99"))
  }

  @Test func `unrecognized errors pass through unchanged`() {
    struct Marker: Error {}
    #expect(ErrorMapper.map(Marker(), usesAppAttest: false) is Marker)
  }

  @Test func `unsupported attestation becomes attestationUnsupported`() {
    guard case ClaudeError.attestationUnsupported = ErrorMapper.map(AppAttestError.unsupported)
    else {
      Issue.record("expected attestationUnsupported")
      return
    }
  }

  @Test func `other attestation failures become attestationFailed`() {
    for error in [AppAttestError.notYetAvailable, .keyInvalidated] {
      guard case ClaudeError.attestationFailed = ErrorMapper.map(error, usesAppAttest: false) else {
        Issue.record("expected attestationFailed for \(error)")
        return
      }
    }
  }
}
