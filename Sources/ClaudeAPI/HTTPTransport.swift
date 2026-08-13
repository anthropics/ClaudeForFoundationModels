// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

/// The HTTP seam ``ClaudeClient`` talks through. Production uses
/// ``URLSessionTransport``; tests inject a fake. The streaming body is surfaced
/// as a byte stream rather than `URLSession.AsyncBytes` so a fake can produce
/// one — `AsyncBytes` can only be vended by a live `URLSession`.
package protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
  func bytes(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse)
}

package enum HTTPTransportError: Error, Sendable, Hashable {
  /// The server redirected to a different scheme, host, or port and the
  /// transport refused to follow. Every request carries a credential minted
  /// for the configured base URL — `x-api-key`, a bearer token, the
  /// developer's proxy headers, or an App Attest assertion in the body — and
  /// `URLSession` forwards all of those except `Authorization` on redirect.
  case crossOriginRedirect(to: URL)
}

extension HTTPTransportError: LocalizedError {
  package var errorDescription: String? {
    switch self {
    case .crossOriginRedirect(let target):
      "Refused a redirect away from the configured base URL (to \(target.host() ?? "?"))."
    }
  }
}

/// `URLSession`-backed transport used in production.
package struct URLSessionTransport: HTTPTransport {
  private let session: URLSession

  package init(session: URLSession = .shared) {
    self.session = session
  }

  package func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let redirects = RedirectPolicy(origin: request.url)
    let (data, response) = try await session.data(for: request, delegate: redirects)
    try redirects.checkRefused()
    return (data, response)
  }

  package func bytes(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
    // `bytes(for:)` returns once headers arrive, so the caller can check the
    // status before draining the body. Re-yield the bytes through a stream of
    // the transport's vocabulary type.
    let redirects = RedirectPolicy(origin: request.url)
    let (asyncBytes, response) = try await session.bytes(for: request, delegate: redirects)
    // Redirects are decided before the response headers are delivered, so a
    // refusal is already recorded by the time `bytes(for:)` returns.
    try redirects.checkRefused()
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      let task = Task {
        do {
          for try await byte in asyncBytes { continuation.yield(byte) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return (stream, response)
  }
}

/// Per-task delegate that follows redirects only within the authority the
/// request was made to. Refusing (rather than stripping known headers) keeps
/// the credential-bearing headers and body off the other host regardless of
/// which auth mode put them there.
///
/// A refused redirect makes `URLSession` complete the task with the 3xx
/// response itself, which callers would otherwise take for a success, so the
/// refusal is recorded and ``checkRefused()`` turns it into an error.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  /// Nil when the request had no usable URL, in which case nothing is
  /// followed.
  private let origin: Authority?
  private let refusedTarget = Mutex<URL?>(nil)

  init(origin: URL?) {
    self.origin = origin.flatMap { Authority($0) }
    super.init()
  }

  /// Compared against the original request, not the previous hop, so a chain
  /// that leaves the authority is refused wherever it leaves.
  func allowsRedirect(to target: URL) -> Bool {
    if let origin, Authority(target) == origin { return true }
    refusedTarget.withLock { $0 = target }
    return false
  }

  func checkRefused() throws {
    if let target = refusedTarget.withLock({ $0 }) {
      throw HTTPTransportError.crossOriginRedirect(to: target)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    if let target = request.url, allowsRedirect(to: target) {
      completionHandler(request)
    } else {
      completionHandler(nil)
    }
  }

  /// The `scheme://host:port` triple a credential is scoped to. An omitted
  /// port equals the scheme's default, so `https://h` and `https://h:443`
  /// are one authority; a scheme change (including an https → http
  /// downgrade) is not.
  struct Authority: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init?(_ url: URL) {
      guard let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else {
        return nil
      }
      self.scheme = scheme
      self.host = host.lowercased()
      self.port = url.port ?? Self.defaultPort(for: scheme)
    }

    private static func defaultPort(for scheme: String) -> Int? {
      switch scheme {
      case "https": 443
      case "http": 80
      default: nil
      }
    }
  }
}
