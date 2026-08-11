// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import ClaudeAPI

/// Redirect handling in `URLSessionTransport`: the decision itself, and the
/// decision wired through a real `URLSession` via a `URLProtocol` stub. The
/// stub routes by host and every test owns two hosts of its own, so the suite
/// runs in parallel.
@Suite struct URLSessionTransportTests {

  // MARK: - Decision

  @Test(arguments: [
    "https://proxy.test/moved",
    "https://proxy.test:443/v1/messages",
    "HTTPS://Proxy.TEST/v1/messages",
  ])
  func `a redirect within the origin's authority is followed`(target: String) {
    let policy = RedirectPolicy(origin: URL(string: "https://proxy.test/v1/messages"))

    #expect(policy.allowsRedirect(to: URL(string: target)!))
    #expect(throws: Never.self) { try policy.checkRefused() }
  }

  @Test(arguments: [
    "https://other.test/v1/messages",
    "https://proxy.test.other.test/v1/messages",
    "https://proxy.test:8443/v1/messages",
    "http://proxy.test/v1/messages",
  ])
  func `a redirect to another authority is refused and reported`(target: String) {
    let policy = RedirectPolicy(origin: URL(string: "https://proxy.test/v1/messages"))
    let url = URL(string: target)!

    #expect(!policy.allowsRedirect(to: url))
    #expect(throws: HTTPTransportError.crossOriginRedirect(to: url)) { try policy.checkRefused() }
  }

  @Test func `an explicit default port matches an omitted one for http too`() {
    let policy = RedirectPolicy(origin: URL(string: "http://proxy.test:80/v1/messages"))

    #expect(policy.allowsRedirect(to: URL(string: "http://proxy.test/moved")!))
    #expect(!policy.allowsRedirect(to: URL(string: "https://proxy.test/moved")!))
  }

  @Test func `nothing is followed when the origin has no authority`() {
    let policy = RedirectPolicy(origin: nil)

    #expect(!policy.allowsRedirect(to: URL(string: "https://proxy.test/moved")!))
    #expect(throws: HTTPTransportError.self) { try policy.checkRefused() }
  }

  // MARK: - Through URLSession

  @Test func `data refuses a redirect to another host`() async throws {
    let stub = Stub("data-cross")
    stub.redirectOrigin(to: stub.otherURL)

    let error = try await #require(throws: HTTPTransportError.self) {
      _ = try await stub.transport.data(for: stub.request())
    }

    guard case .crossOriginRedirect(let target) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(target.host() == stub.otherHost)
    // The other host never saw a request, credentials or otherwise.
    #expect(stub.receivedHosts == [stub.originHost])
  }

  @Test func `bytes refuses a redirect to another host`() async throws {
    let stub = Stub("bytes-cross")
    stub.redirectOrigin(to: stub.otherURL)

    let error = try await #require(throws: HTTPTransportError.self) {
      _ = try await stub.transport.bytes(for: stub.request())
    }

    guard case .crossOriginRedirect(let target) = error else {
      Issue.record("unexpected error \(error)")
      return
    }
    #expect(target.host() == stub.otherHost)
    #expect(stub.receivedHosts == [stub.originHost])
  }

  @Test func `data follows an origin-host redirect and keeps the credentials`() async throws {
    let stub = Stub("data-same")
    stub.redirectOrigin(to: stub.movedURL)

    let (body, response) = try await stub.transport.data(for: stub.request())

    #expect(String(decoding: body, as: UTF8.self) == "ok")
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(stub.receivedHosts == [stub.originHost, stub.originHost])
    let followUp = try #require(stub.received.last)
    #expect(followUp.url?.path() == "/moved")
    #expect(followUp.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(followUp.value(forHTTPHeaderField: "X-App-Token") == "app-secret")
  }

  @Test func `bytes follows an origin-host redirect and keeps the credentials`() async throws {
    let stub = Stub("bytes-same")
    stub.redirectOrigin(to: stub.movedURL)

    let (bytes, response) = try await stub.transport.bytes(for: stub.request())
    var body = Data()
    for try await byte in bytes { body.append(byte) }

    #expect(String(decoding: body, as: UTF8.self) == "ok")
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(stub.receivedHosts == [stub.originHost, stub.originHost])
    let followUp = try #require(stub.received.last)
    #expect(followUp.url?.path() == "/moved")
    #expect(followUp.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(followUp.value(forHTTPHeaderField: "X-App-Token") == "app-secret")
  }
}

// MARK: - Stub

/// One test's slice of ``StubProtocol``: an origin host whose `/v1/messages`
/// answers with a 307, and a second host standing in for wherever the
/// redirect points. Every other request on either host answers 200 `ok`.
private struct Stub {
  let originHost: String
  let otherHost: String
  let transport: URLSessionTransport
  private let recorder = Recorder()

  init(_ name: String) {
    originHost = "origin-\(name).test"
    otherHost = "other-\(name).test"
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    transport = URLSessionTransport(session: URLSession(configuration: configuration))
  }

  var otherURL: URL { URL(string: "https://\(otherHost)/v1/messages")! }
  var movedURL: URL { URL(string: "https://\(originHost)/moved")! }

  /// Every request the stub served, in order, across both hosts.
  var received: [URLRequest] { recorder.requests.withLock { $0 } }
  var receivedHosts: [String] { received.compactMap { $0.url?.host() } }

  func redirectOrigin(to target: URL) {
    let recorder = self.recorder
    let originHost = self.originHost
    StubProtocol.register(hosts: [originHost, otherHost]) { request in
      recorder.requests.withLock { $0.append(request) }
      let isOriginEndpoint =
        request.url?.host() == originHost && request.url?.path() == "/v1/messages"
      return isOriginEndpoint ? .redirect(to: target) : .ok
    }
  }

  /// Carries a credential in each of the header positions the SDK uses:
  /// `x-api-key` for `.apiKey`, and a developer header for `.proxied`.
  func request() -> URLRequest {
    var request = URLRequest(url: URL(string: "https://\(originHost)/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("sk-test", forHTTPHeaderField: "x-api-key")
    request.setValue("app-secret", forHTTPHeaderField: "X-App-Token")
    return request
  }
}

private final class Recorder: Sendable {
  let requests = Mutex<[URLRequest]>([])
}

/// Serves the hosts handed to ``register(hosts:handler:)`` without touching
/// the network. A `.redirect` reply goes through `URLSession`'s redirect
/// machinery, so the task delegate under test decides whether the follow-up
/// request is loaded.
private final class StubProtocol: URLProtocol {
  enum Reply: Sendable {
    case redirect(to: URL)
    case ok
  }

  typealias Handler = @Sendable (URLRequest) -> Reply

  private static let handlers = Mutex<[String: Handler]>([:])

  static func register(hosts: [String], handler: @escaping Handler) {
    handlers.withLock { table in
      for host in hosts { table[host] = handler }
    }
  }

  private static func handler(for request: URLRequest) -> Handler? {
    guard let host = request.url?.host() else { return nil }
    return handlers.withLock { $0[host] }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    handler(for: request) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let client, let url = request.url, let handler = StubProtocol.handler(for: request) else {
      return
    }
    switch handler(request) {
    case .redirect(let target):
      let response = HTTPURLResponse(
        url: url,
        statusCode: 307,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString]
      )!
      // Shaped like the request Foundation proposes for a 307: same method,
      // body, and custom headers, new URL — exactly what leaks if followed.
      var next = request
      next.url = target
      client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
      // When the delegate declines, the redirect response itself completes
      // the task; when it accepts, this load is stopped and these are dropped.
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client.urlProtocolDidFinishLoading(self)
    case .ok:
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client.urlProtocol(self, didLoad: Data("ok".utf8))
      client.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}
