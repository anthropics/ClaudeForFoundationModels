// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

/// Maps Messages API failures onto the framework's typed errors so app
/// developers can pattern-match on well-known cases.
enum ErrorMapper {
  static func map(_ error: any Error) -> any Error {
    if let api = error as? APIError {
      return map(api)
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

  static func map(_ error: APIError) -> any Error {
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
      return ClaudeError.missingCredential
    case .permission, .api, .invalidRequest, .notFound, .other:
      // No honest framework-error equivalent — surface the API error itself.
      // `.permission` means the credential exists but isn't allowed here;
      // calling that a missing credential would send users to key entry.
      return error
    }
  }
}
