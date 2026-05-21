// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Error envelope returned by the API (both in HTTP error bodies and as an
/// SSE `error` event).
package struct APIError: Error, Sendable, Hashable, Codable {
  package enum Kind: String, Sendable, Codable {
    case invalidRequest = "invalid_request_error"
    case authentication = "authentication_error"
    case permission = "permission_error"
    case notFound = "not_found_error"
    case requestTooLarge = "request_too_large"
    case rateLimit = "rate_limit_error"
    case api = "api_error"
    case overloaded = "overloaded_error"
    /// Forward-compatibility: an unrecognized error type still surfaces as a
    /// typed `APIError` carrying the API's message, not a `DecodingError`.
    case other

    package init(from decoder: Decoder) throws {
      let raw = try decoder.singleValueContainer().decode(String.self)
      self = Kind(rawValue: raw) ?? .other
    }
  }

  package var kind: Kind
  package var message: String
  package var requestID: String?

  package init(kind: Kind, message: String, requestID: String? = nil) {
    self.kind = kind
    self.message = message
    self.requestID = requestID
  }

  private enum CodingKeys: String, CodingKey { case type, message }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decode(Kind.self, forKey: .type)
    message = try c.decode(String.self, forKey: .message)
    requestID = nil
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .type)
    try c.encode(message, forKey: .message)
  }
}

extension APIError: LocalizedError {
  package var errorDescription: String? {
    "\(kind.rawValue): \(message)" + (requestID.map { " (request_id: \($0))" } ?? "")
  }
}

/// Top-level error body: `{ "type": "error", "error": {...}, "request_id": "..." }`
struct APIErrorEnvelope: Decodable {
  var error: APIError
  var requestID: String?
  private enum CodingKeys: String, CodingKey {
    case error
    case requestID = "request_id"
  }
}
