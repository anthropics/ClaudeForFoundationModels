// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import ClaudeAPI

/// Drives `ClaudeClient` through an injected fake transport so request building,
/// HTTP error mapping, and SSE parsing are exercised without a network. Each
/// test owns its transport, so the suite runs in parallel.
@Suite struct ClaudeClientTests {

  // MARK: - Non-streaming

  @Test func `send builds the request and decodes the response`() async throws {
    let transport = MockTransport(
      headers: ["Content-Type": "application/json"],
      body: Data(
        #"""
        {"id":"msg_1","model":"m","role":"assistant","content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":1}}
        """#
        .utf8
      )
    )

    let response = try await client(transport)
      .send(
        MessagesRequest(model: "m", maxTokens: 256, messages: [.user("hi")])
      )

    #expect(response.content == [.text("Hi")])
    #expect(response.stopReason == .endTurn)

    let request = try #require(transport.lastRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path() == "/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(
      request.value(forHTTPHeaderField: "User-Agent")?.contains("ClaudeForFoundationModels/")
        == true
    )

    // The request goes straight to the transport, so its httpBody is intact
    // (URLSession would have moved it into httpBodyStream).
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "m")
    #expect(json["max_tokens"] as? Int == 256)
    #expect(json["stream"] as? Bool == false)  // send() forces non-streaming
    #expect((json["messages"] as? [[String: Any]])?.count == 1)
  }

  @Test func `caller headers merge over the defaults`() async throws {
    // This is the mechanism `.proxied(headers:)` rides on: the executor passes
    // its auth headers as `headers:`, and the client merges them over its
    // defaults without dropping `x-api-key` / `anthropic-version`.
    let transport = MockTransport(
      body: Data(
        #"{"id":"m","model":"m","role":"assistant","content":[],"stop_reason":"end_turn","usage":{"output_tokens":0}}"#
          .utf8
      )
    )

    _ = try await client(transport)
      .send(
        MessagesRequest(model: "m", messages: [.user("hi")]),
        headers: ["X-App-Token": "abc", "anthropic-beta": "feature-1"]
      )

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "X-App-Token") == "abc")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "feature-1")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
  }

  @Test func `send maps an error envelope to a typed APIError`() async throws {
    let transport = MockTransport(
      status: 429,
      body: Data(
        #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"},"request_id":"req_envelope"}"#
          .utf8
      )
    )

    let error = try await #require(throws: APIError.self) {
      try await client(transport).send(MessagesRequest(model: "m", messages: [.user("hi")]))
    }
    #expect(error.kind == .rateLimit)
    #expect(error.requestID == "req_envelope")
  }

  @Test func `send falls back to the request-id header when the body has no envelope`() async throws
  {
    let transport = MockTransport(
      status: 500,
      headers: ["request-id": "req_header"],
      body: Data("<html>upstream blew up</html>".utf8)
    )

    let error = try await #require(throws: APIError.self) {
      try await client(transport).send(MessagesRequest(model: "m", messages: [.user("hi")]))
    }
    #expect(error.kind == .api)
    #expect(error.requestID == "req_header")
    #expect(error.message.contains("HTTP 500"))
  }

  // MARK: - Streaming

  @Test func `stream parses frames, surfaces ping, and ends on message_stop`() async throws {
    let transport = MockTransport(
      body: sse([
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
        ],
        ["event: ping", #"data: {"type":"ping"}"#],
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
        ],
        ["event: message_stop", #"data: {"type":"message_stop"}"#],
      ])
    )

    var events: [StreamEvent] = []
    for try await event in client(transport)
      .stream(
        MessagesRequest(model: "m", messages: [.user("hi")])
      )
    {
      events.append(event)
    }

    let texts = events.compactMap {
      if case .contentBlockDelta(_, .text(let t)) = $0 { t } else { nil }
    }
    #expect(texts == ["Hel", "lo"])
    #expect(events.contains { if case .ping = $0 { true } else { false } })
    #expect(events.contains { if case .messageStop = $0 { true } else { false } })
  }

  @Test func `stream concatenates a multi-line data frame`() async throws {
    let transport = MockTransport(
      body: sse([
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":"#,
          #"data: {"type":"text_delta","text":"multi"}}"#,
        ]
      ])
    )

    var texts: [String] = []
    for try await event in client(transport)
      .stream(
        MessagesRequest(model: "m", messages: [.user("hi")])
      )
    {
      if case .contentBlockDelta(_, .text(let t)) = event { texts.append(t) }
    }
    #expect(texts == ["multi"])
  }

  @Test func `stream throws when the body carries an SSE error event`() async throws {
    let transport = MockTransport(
      body: sse([
        [
          "event: error",
          #"data: {"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#,
        ]
      ])
    )

    let error = try await #require(throws: APIError.self) {
      for try await _ in client(transport)
        .stream(
          MessagesRequest(model: "m", messages: [.user("hi")])
        )
      {}
    }
    #expect(error.kind == .overloaded)
  }

  @Test func `a non-envelope error body classifies by HTTP status`() async throws {
    let transport = MockTransport(status: 401, body: Data("<html>denied</html>".utf8))

    let error = try await #require(throws: APIError.self) {
      for try await _ in client(transport)
        .stream(
          MessagesRequest(model: "m", messages: [.user("hi")])
        )
      {}
    }
    #expect(error.kind == .authentication)
  }

  @Test func `stream maps a 4xx error body instead of parsing it as SSE`() async throws {
    let transport = MockTransport(
      status: 400,
      body: Data(
        #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#.utf8
      )
    )

    let error = try await #require(throws: APIError.self) {
      for try await _ in client(transport)
        .stream(
          MessagesRequest(model: "m", messages: [.user("hi")])
        )
      {}
    }
    #expect(error.kind == .invalidRequest)
  }

  @Test func `streamText yields cumulative snapshots`() async throws {
    let transport = MockTransport(
      body: sse([
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
        ],
        [
          "event: content_block_delta",
          #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
        ],
        ["event: message_stop", #"data: {"type":"message_stop"}"#],
      ])
    )

    var snapshots: [String] = []
    for try await snapshot in client(transport)
      .streamText(
        MessagesRequest(model: "m", messages: [.user("hi")])
      )
    {
      snapshots.append(snapshot)
    }
    #expect(snapshots == ["Hel", "Hello"])
  }

  // MARK: - Helpers

  private func client(
    _ transport: any HTTPTransport,
    auth: Configuration.Auth = .apiKey("sk-test")
  ) -> ClaudeClient {
    ClaudeClient(
      configuration: .init(auth: auth, baseURL: URL(string: "https://stub.test")!),
      transport: transport
    )
  }

  /// A `text/event-stream` body: each frame is its lines followed by the
  /// blank line that terminates it, exactly as the API frames them.
  private func sse(_ frames: [[String]]) -> Data {
    Data(frames.map { $0.joined(separator: "\n") + "\n\n" }.joined().utf8)
  }
}

/// An `HTTPTransport` that returns a canned response and records the request it received.
private final class MockTransport: HTTPTransport {
  let status: Int
  let headers: [String: String]
  let body: Data

  private let captured = Mutex<URLRequest?>(nil)

  init(status: Int = 200, headers: [String: String] = [:], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  var lastRequest: URLRequest? { captured.withLock { $0 } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    record(request)
    return (body, response(for: request))
  }

  func bytes(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
    record(request)
    let body = self.body
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      for byte in body { continuation.yield(byte) }
      continuation.finish()
    }
    return (stream, response(for: request))
  }

  private func record(_ request: URLRequest) {
    captured.withLock { $0 = request }
  }

  private func response(for request: URLRequest) -> URLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }
}
