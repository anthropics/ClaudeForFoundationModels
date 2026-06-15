// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

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
