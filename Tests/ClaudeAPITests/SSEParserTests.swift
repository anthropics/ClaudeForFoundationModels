// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeAPI

@Suite struct SSEParserTests {
  @Test(.timeLimit(.minutes(1)))
  func `an event is delivered as soon as its frame ends`() async throws {
    let (bytes, continuation) = AsyncThrowingStream<UInt8, Error>.makeStream()
    let frame = "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":3}\n\n"
    for byte in Data(frame.utf8) { continuation.yield(byte) }
    // The byte stream stays open: the event must arrive off the frame's own
    // blank line, not wait for a following frame or end of stream.
    var iterator = SSEParser.events(from: bytes).makeAsyncIterator()
    let event = try #require(await iterator.next())
    guard case .contentBlockStop(let index) = event else {
      Issue.record("expected contentBlockStop, got \(event)")
      continuation.finish()
      return
    }
    #expect(index == 3)
    continuation.finish()
  }

  @Test func `crlf line endings parse like lf`() async throws {
    let events = try await collect(
      "event: ping\r\ndata: {\"type\":\"ping\"}\r\n\r\n"
        + "event: message_stop\r\ndata: {\"type\":\"message_stop\"}\r\n\r\n"
    )
    #expect(events.count == 2)
  }

  @Test func `a final frame without a trailing blank line flushes at end of stream`() async throws {
    let events = try await collect("event: ping\ndata: {\"type\":\"ping\"}")
    #expect(events.count == 1)
  }

  // MARK: - Helpers

  private func collect(_ body: String) async throws -> [StreamEvent] {
    let bytes = AsyncThrowingStream<UInt8, Error> { continuation in
      for byte in Data(body.utf8) { continuation.yield(byte) }
      continuation.finish()
    }
    var events: [StreamEvent] = []
    for try await event in SSEParser.events(from: bytes) {
      events.append(event)
    }
    return events
  }
}
