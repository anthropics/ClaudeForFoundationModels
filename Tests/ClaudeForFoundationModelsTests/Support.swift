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

/// Serves a canned body for every request and records the last request.
final class MockTransport: HTTPTransport {
  let status: Int
  let body: Data
  private let captured = Mutex<URLRequest?>(nil)

  init(status: Int = 200, body: Data) {
    self.status = status
    self.body = body
  }

  var lastRequest: URLRequest? { captured.withLock { $0 } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    captured.withLock { $0 = request }
    return (body, response(request))
  }

  func bytes(
    for request: URLRequest
  ) async throws -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
    captured.withLock { $0 = request }
    let body = self.body
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      for byte in body { continuation.yield(byte) }
      continuation.finish()
    }
    return (stream, response(request))
  }

  private func response(_ request: URLRequest) -> URLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
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

/// Equatable mirror of the channel events the bridge emits, so tests can
/// assert on whole event sequences — the framework's event types aren't
/// `Equatable`.
enum RecordedEvent: Equatable {
  case responseText(entryID: String?, text: String, tokenCount: Int)
  case responseCustomSegment(
    entryID: String?,
    segmentID: String,
    content: ClaudeServerToolSegment.Content
  )
  case responseUsage(
    entryID: String?,
    inputTotal: Int,
    inputCached: Int,
    outputTotal: Int,
    outputReasoning: Int
  )
  case reasoningText(entryID: String?, text: String, tokenCount: Int)
  case reasoningSignature(entryID: String?, signature: Data)
  case reasoningMetadata(entryID: String?, keys: [String])
  case toolCallArguments(
    entryID: String?,
    id: String,
    name: String,
    arguments: String,
    tokenCount: Int
  )
  case other(String)

  init(_ event: any LanguageModelExecutorGenerationChannel.Event) {
    typealias Channel = LanguageModelExecutorGenerationChannel
    switch event {
    case let response as Channel.Response:
      switch response.action {
      case .appendText(let fragment):
        self = .responseText(
          entryID: response.entryID,
          text: fragment.content,
          tokenCount: fragment.tokenCount
        )
      case .updateCustomSegment(let segment):
        if let segment = segment as? ClaudeServerToolSegment {
          self = .responseCustomSegment(
            entryID: response.entryID,
            segmentID: segment.id,
            content: segment.content
          )
        } else {
          self = .other(String(describing: segment))
        }

      case .updateUsage(let usage):
        self = .responseUsage(
          entryID: response.entryID,
          inputTotal: usage.input.totalTokenCount,
          inputCached: usage.input.cachedTokenCount,
          outputTotal: usage.output.totalTokenCount,
          outputReasoning: usage.output.reasoningTokenCount
        )
      default:
        self = .other(String(describing: response.action))
      }

    case let reasoning as Channel.Reasoning:
      switch reasoning.action {
      case .appendText(let fragment):
        self = .reasoningText(
          entryID: reasoning.entryID,
          text: fragment.content,
          tokenCount: fragment.tokenCount
        )
      case .updateSignature(let signature):
        self = .reasoningSignature(entryID: reasoning.entryID, signature: signature.signature)
      case .updateMetadata(let metadata):
        self = .reasoningMetadata(entryID: reasoning.entryID, keys: metadata.values.keys.sorted())
      default:
        self = .other(String(describing: reasoning.action))
      }

    case let toolCalls as Channel.ToolCalls:
      switch toolCalls.action {
      case .toolCall(let call):
        switch call.action {
        case .appendArguments(let fragment):
          self = .toolCallArguments(
            entryID: toolCalls.entryID,
            id: call.id,
            name: call.name,
            arguments: fragment.content,
            tokenCount: fragment.tokenCount
          )
        default:
          self = .other(String(describing: call.action))
        }
      default:
        self = .other(String(describing: toolCalls.action))
      }

    default:
      self = .other(String(describing: event))
    }
  }
}

/// Runs `produce` against a fresh channel and returns every event it sent, in
/// order. The channel has no finish API, so a sentinel response event marks
/// the end of production and terminates the drain. Errors from `produce`
/// surface after the drain, mirroring how the framework consumes the channel.
func recordedEvents(
  _ produce: @escaping @Sendable (LanguageModelExecutorGenerationChannel) async throws -> Void
) async throws -> [RecordedEvent] {
  let channel = LanguageModelExecutorGenerationChannel()
  let sentinelID = "test.sentinel"

  let producer = Task {
    let sentinel: LanguageModelExecutorGenerationChannel.Response = .response(
      entryID: sentinelID,
      action: .appendText("", tokenCount: 0)
    )
    do {
      try await produce(channel)
    } catch {
      await channel.send(sentinel)
      throw error
    }
    await channel.send(sentinel)
  }

  var events: [RecordedEvent] = []
  for try await event in channel {
    if let response = event as? LanguageModelExecutorGenerationChannel.Response,
      response.entryID == sentinelID
    {
      break
    }
    events.append(RecordedEvent(event))
  }
  try await producer.value
  return events
}
