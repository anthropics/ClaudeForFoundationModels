// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Parses a `text/event-stream` byte stream into ``StreamEvent`` values.
///
/// SSE frames are `event:` + one or more `data:` lines terminated by a blank
/// line. Lines are split here rather than with `AsyncSequence.lines`, which
/// swallows the blank separator — the frame must be emitted the moment its
/// blank line arrives, not when the next frame starts, or every event would be
/// delivered one frame late.
enum SSEParser {
  static func events(
    from bytes: AsyncThrowingStream<UInt8, Error>
  ) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let decoder = JSONDecoder()
          var data = ""
          func flush() throws {
            guard !data.isEmpty else { return }
            try emit(data, with: decoder, to: continuation)
            data = ""
          }
          func handle(_ line: String) throws {
            if line.isEmpty {
              // Blank line — end of frame.
              try flush()
            } else if line.hasPrefix("data:") {
              let payload = line.dropFirst(5)
                .trimmingCharacters(in: .whitespaces)
              data += data.isEmpty ? payload : "\n" + payload
            }
            // `event:` / `id:` / `retry:` / `:` comment — nothing to do; the
            // payload's own `type` field discriminates the event.
          }

          // Lines end with LF, CRLF, or CR. A lone LF directly after a CR is
          // the tail of a CRLF, not a new (blank) line.
          var line: [UInt8] = []
          var previousByteWasCR = false
          for try await byte in bytes {
            switch byte {
            case UInt8(ascii: "\n") where previousByteWasCR:
              previousByteWasCR = false
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
              previousByteWasCR = byte == UInt8(ascii: "\r")
              try handle(String(decoding: line, as: UTF8.self))
              line.removeAll(keepingCapacity: true)
            default:
              previousByteWasCR = false
              line.append(byte)
            }
          }
          if !line.isEmpty {
            try handle(String(decoding: line, as: UTF8.self))
          }
          try flush()
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func emit(
    _ json: String,
    with decoder: JSONDecoder,
    to continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
  ) throws {
    guard json != "[DONE]" else { return }
    let event = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    if case .error(let apiError) = event {
      throw apiError
    }
    continuation.yield(event)
  }
}
