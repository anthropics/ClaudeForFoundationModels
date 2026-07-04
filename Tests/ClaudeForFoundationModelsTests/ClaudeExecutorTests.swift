// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

@Suite struct ClaudeExecutorTests {
  @Test func `api key auth sends x-api-key`() async throws {
    let transport = MockTransport(body: okStream)
    let executor = ClaudeExecutor(configuration: config(.apiKey("sk-test")), transport: transport)

    _ = try await recordedEvents { channel in
      try await executor.respond(
        to: prompt(),
        model: model(.apiKey("sk-test")),
        streamingInto: channel
      )
    }

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
  }

  @Test func `proxied auth sends the proxy headers and no api key`() async throws {
    let auth = AuthMode.proxied(headers: ["X-App-Token": "abc"])
    let transport = MockTransport(body: okStream)
    let executor = ClaudeExecutor(configuration: config(auth), transport: transport)

    _ = try await recordedEvents { channel in
      try await executor.respond(to: prompt(), model: model(auth), streamingInto: channel)
    }

    let request = try #require(transport.lastRequest)
    #expect(request.value(forHTTPHeaderField: "X-App-Token") == "abc")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
  }

  @Test func `an empty api key fails with missingCredential before any request`() async throws {
    let transport = MockTransport(body: okStream)
    let executor = ClaudeExecutor(configuration: config(.apiKey("")), transport: transport)

    let error = try await #require(throws: ClaudeError.self) {
      try await recordedEvents { channel in
        try await executor.respond(
          to: prompt(),
          model: model(.apiKey("")),
          streamingInto: channel
        )
      }
    }
    guard case .missingCredential = error else {
      Issue.record("expected missingCredential, got \(error)")
      return
    }
    #expect(transport.lastRequest == nil)  // auth is checked before the transport runs
  }

  @Test func `a streamed response reaches the channel`() async throws {
    let transport = MockTransport(body: okStream)
    let executor = ClaudeExecutor(configuration: config(.apiKey("sk-test")), transport: transport)

    let events = try await recordedEvents { channel in
      try await executor.respond(
        to: prompt(),
        model: model(.apiKey("sk-test")),
        streamingInto: channel
      )
    }

    let texts = events.compactMap {
      if case .responseText(_, let t, _) = $0 { t } else { nil }
    }
    #expect(texts.contains("Hi"))
  }

  @Test func `a streamed API error is mapped to a typed LanguageModelError`() async throws {
    let transport = MockTransport(
      status: 429,
      body: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#.utf8)
    )
    let executor = ClaudeExecutor(configuration: config(.apiKey("sk-test")), transport: transport)

    let error = try await #require(throws: LanguageModelError.self) {
      try await recordedEvents { channel in
        try await executor.respond(
          to: prompt(),
          model: model(.apiKey("sk-test")),
          streamingInto: channel
        )
      }
    }
    guard case .rateLimited = error else {
      Issue.record("expected rateLimited, got \(error)")
      return
    }
  }

  // MARK: - Fixtures

  private func config(_ auth: AuthMode) -> ClaudeExecutor.Configuration {
    .init(
      model: .sonnet4_6,
      baseURL: ClaudeLanguageModel.defaultBaseURL,
      authMode: auth,
      timeout: 60
    )
  }

  private func model(_ auth: AuthMode) -> ClaudeLanguageModel {
    ClaudeLanguageModel(name: .sonnet4_6, auth: auth)
  }

  private func prompt() -> LanguageModelExecutorGenerationRequest {
    .make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "hi"))]))])
    )
  }

  /// SSE frames as the API sends them: `event:` + `data:` lines, each frame
  /// terminated by a blank line.
  private let okStream = sseBody([
    [
      "event: content_block_start",
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    ],
    [
      "event: content_block_delta",
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
    ],
    ["event: message_stop", #"data: {"type":"message_stop"}"#],
  ])
}
