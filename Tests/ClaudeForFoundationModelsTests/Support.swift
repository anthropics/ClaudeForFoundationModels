// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import CoreGraphics
import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import ClaudeForFoundationModels

/// Joins SSE frames (each an array of `event:`/`data:` lines) into a wire body.
func sseBody(_ frames: [[String]]) -> Data {
  Data(frames.map { $0.joined(separator: "\n") + "\n\n" }.joined().utf8)
}

/// A complete assistant turn streaming `deltas` in one text block.
func textTurn(
  deltas: [String],
  inputTokens: Int = 10,
  cacheReadTokens: Int = 0,
  cacheCreationTokens: Int = 0,
  outputTokens: Int = 5
) -> Data {
  var frames: [[String]] = [
    [
      "event: message_start",
      #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input_tokens":\#(inputTokens),"output_tokens":1,"cache_read_input_tokens":\#(cacheReadTokens),"cache_creation_input_tokens":\#(cacheCreationTokens)}}}"#,
    ],
    [
      "event: content_block_start",
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    ],
  ]
  for delta in deltas {
    let escaped = String(decoding: try! JSONEncoder().encode(delta), as: UTF8.self)
    frames.append([
      "event: content_block_delta",
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(escaped)}}"#,
    ])
  }
  frames += [
    ["event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#],
    [
      "event: message_delta",
      #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":\#(outputTokens)}}"#,
    ],
    ["event: message_stop", #"data: {"type":"message_stop"}"#],
  ]
  return sseBody(frames)
}

/// A complete assistant turn: one thinking block, then a `"Hello!"` text block.
/// An empty `thinkingDeltas` mimics `display: omitted`, where the thinking
/// block streams signature-only.
func thinkingTurnSSE(thinkingDeltas: [String]) -> Data {
  var frames: [[String]] = [
    [
      "event: message_start",
      #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1}}}"#,
    ],
    [
      "event: content_block_start",
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
    ],
  ]
  for delta in thinkingDeltas {
    let escaped = String(decoding: try! JSONEncoder().encode(delta), as: UTF8.self)
    frames.append([
      "event: content_block_delta",
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":\#(escaped)}}"#,
    ])
  }
  frames += [
    [
      "event: content_block_delta",
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"c2ln"}}"#,
    ],
    ["event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#],
    [
      "event: content_block_start",
      #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
    ],
    [
      "event: content_block_delta",
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello!"}}"#,
    ],
    ["event: content_block_stop", #"data: {"type":"content_block_stop","index":1}"#],
    [
      "event: message_delta",
      #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
    ],
    ["event: message_stop", #"data: {"type":"message_stop"}"#],
  ]
  return sseBody(frames)
}

/// Text of every reasoning entry in the transcript, in order, joined.
func reasoningText(in transcript: Transcript) -> String {
  reasoningEntries(in: transcript)
    .flatMap(\.segments)
    .compactMap { segment -> String? in
      if case .text(let t) = segment { return t.content }
      return nil
    }
    .joined()
}

/// Reasoning entries in the transcript, in order.
func reasoningEntries(in transcript: Transcript) -> [Transcript.Reasoning] {
  transcript.compactMap { entry in
    if case .reasoning(let r) = entry { return r }
    return nil
  }
}

/// An assistant turn whose thought arrives as an opaque `redacted_thinking`
/// block, then a `"Hello!"` text block.
func redactedThinkingTurnSSE(payload: Data) -> Data {
  sseBody([
    [
      "event: message_start",
      #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1}}}"#,
    ],
    [
      "event: content_block_start",
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"\#(payload.base64EncodedString())"}}"#,
    ],
    ["event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#],
    [
      "event: content_block_start",
      #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
    ],
    [
      "event: content_block_delta",
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello!"}}"#,
    ],
    ["event: content_block_stop", #"data: {"type":"content_block_stop","index":1}"#],
    [
      "event: message_delta",
      #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
    ],
    ["event: message_stop", #"data: {"type":"message_stop"}"#],
  ])
}

/// Canned App Attest wire bodies shared across suites.
enum WireFixtures {
  /// 32 bytes of 0x01, the golden-vector challenge.
  static let challengeBody = Data(
    #"{"challenge":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","expires_in":300}"#.utf8
  )

  /// The pre-issued challenge is the same nonce as `challengeBody`.
  static func oauthBody(token: String, nextChallengeExpiresIn: Double? = nil) -> Data {
    var json = #"{"access_token":"\#(token)","token_type":"Bearer","expires_in":3600"#
    if let nextChallengeExpiresIn {
      json += #","next_challenge":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","#
      json += #""next_challenge_expires_in":\#(nextChallengeExpiresIn)"#
    }
    json += "}"
    return Data(json.utf8)
  }
}

/// Serves the configured responses in order, repeating the last one, and
/// records every request it saw.
final class MockTransport: HTTPTransport {
  private struct CannedResponse {
    let status: Int
    let body: Data
    var headers: [String: String]? = nil
  }

  private let responses: [CannedResponse]
  private let recorded = Mutex<[URLRequest]>([])

  init(status: Int = 200, body: Data) {
    self.responses = [CannedResponse(status: status, body: body)]
  }

  convenience init(responses: [(status: Int, body: Data)]) {
    self.init(responses: responses.map { ($0.status, $0.body, nil) })
  }

  init(responses: [(status: Int, body: Data, headers: [String: String]?)]) {
    precondition(!responses.isEmpty, "MockTransport needs at least one response")
    self.responses = responses.map {
      CannedResponse(status: $0.status, body: $0.body, headers: $0.headers)
    }
  }

  var lastRequest: URLRequest? { recorded.withLock { $0.last } }
  var requests: [URLRequest] { recorded.withLock { $0 } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let canned = next(recording: request)
    return (canned.body, response(request, canned))
  }

  func bytes(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
    let canned = next(recording: request)
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      for byte in canned.body { continuation.yield(byte) }
      continuation.finish()
    }
    return (stream, response(request, canned))
  }

  private func next(recording request: URLRequest) -> CannedResponse {
    recorded.withLock {
      $0.append(request)
      return responses[min($0.count - 1, responses.count - 1)]
    }
  }

  private func response(_ request: URLRequest, _ canned: CannedResponse) -> URLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: canned.status,
      httpVersion: "HTTP/1.1",
      headerFields: canned.headers
    )!
  }
}

/// A small solid-red image for exercising attachment paths.
func makeTestImage(width: Int = 4, height: Int = 4) -> CGImage {
  let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()!
}

extension LanguageModelExecutorGenerationRequest {
  /// The SDK's memberwise initializer has no defaults; tests only vary a few
  /// fields.
  static func make(
    transcript: Transcript,
    enabledTools: [Transcript.ToolDefinition] = [],
    schema: GenerationSchema? = nil,
    generationOptions: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions()
  ) -> Self {
    Self(
      id: UUID(),
      transcript: transcript,
      enabledTools: enabledTools,
      schema: schema,
      generationOptions: generationOptions,
      contextOptions: contextOptions,
      metadata: [:]
    )
  }
}

/// A `LanguageModel` whose executor is a real `ClaudeExecutor` over an
/// injected transport, so `LanguageModelSession` exercises the full pipeline
/// offline — request building, wire auth, SSE parsing, translation, and the
/// framework's transcript assembly.
struct StubbedClaudeModel: LanguageModel {
  typealias Executor = StubbedExecutor

  let transport: MockTransport
  let auth: AuthMode
  let attestSession: AppAttestSession?
  let capabilitySet: [LanguageModelCapabilities.Capability]

  init(
    transport: MockTransport,
    auth: AuthMode = .apiKey("sk-test"),
    attestSession: AppAttestSession? = nil,
    capabilities: [LanguageModelCapabilities.Capability] = [.toolCalling, .reasoning]
  ) {
    self.transport = transport
    self.auth = auth
    self.attestSession = attestSession
    self.capabilitySet = capabilities
  }

  init(fixture: Data) {
    self.init(transport: MockTransport(body: fixture))
  }

  var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities(capabilitySet)
  }

  var executorConfiguration: StubbedExecutor.Configuration {
    .init(transport: transport, auth: auth, attestSession: attestSession)
  }
}

struct StubbedExecutor: LanguageModelExecutor {
  typealias Model = StubbedClaudeModel

  struct Configuration: Hashable, Sendable {
    let transport: MockTransport
    let auth: AuthMode
    let attestSession: AppAttestSession?

    static func == (a: Self, b: Self) -> Bool {
      a.transport === b.transport && a.auth == b.auth && a.attestSession === b.attestSession
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(transport))
      hasher.combine(auth)
    }
  }

  private let configuration: Configuration
  private let inner: ClaudeExecutor

  init(configuration: Configuration) throws {
    self.configuration = configuration
    self.inner = ClaudeExecutor(
      configuration: .init(
        model: .sonnet5,
        baseURL: URL(string: "https://stub.invalid")!,
        authMode: configuration.auth,
        timeout: 5
      ),
      transport: configuration.transport,
      attestSession: configuration.attestSession
    )
  }

  func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: StubbedClaudeModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    try await inner.respond(
      to: request,
      model: ClaudeLanguageModel(name: .sonnet5, auth: configuration.auth),
      streamingInto: channel
    )
  }
}

/// Server-tool segments of every response entry in the transcript, in order.
func serverToolSegments(in transcript: Transcript) -> [ClaudeServerToolSegment] {
  transcript
    .flatMap { entry -> [Transcript.Segment] in
      if case .response(let response) = entry { return response.segments }
      return []
    }
    .compactMap { segment in
      if case .custom(let custom) = segment { return custom as? ClaudeServerToolSegment }
      return nil
    }
}
