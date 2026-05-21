// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeForFoundationModels
import Foundation
import FoundationModels

/// Streams one chat turn against Claude through `LanguageModelSession` and
/// renders it in the terminal, with token usage on a trailing line.
///
///     ANTHROPIC_API_KEY=<key> swift run ClaudeExample "What should I see in Kyoto?"
///
/// Pass `--search` to let Claude search the web server-side:
///
///     ANTHROPIC_API_KEY=<key> swift run ClaudeExample --search "Top spaceflight news this week?"
@main
struct ClaudeExample {
  static func main() async {
    guard
      let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
      !key.isEmpty
    else {
      fail("Set ANTHROPIC_API_KEY to run this example.")
    }

    var arguments = Array(CommandLine.arguments.dropFirst())
    let searchEnabled = arguments.contains("--search")
    arguments.removeAll { $0 == "--search" }
    let prompt =
      arguments.isEmpty
      ? "Plan a 4-day trip to Buenos Aires."
      : arguments.joined(separator: " ")

    let model = ClaudeLanguageModel(
      name: .sonnet4_6,
      auth: .apiKey(key),
      serverTools: searchEnabled ? [.webSearch(maxUses: 3)] : []
    )

    let session = LanguageModelSession(
      model: model,
      instructions: "You are a concise assistant."
    )

    do {
      // Snapshots are cumulative; print only what's new since the last one.
      var printed = ""
      for try await snapshot in session.streamResponse(to: prompt) {
        print(snapshot.content.dropFirst(printed.count), terminator: "")
        fflush(stdout)  // deltas are sub-line; stdout is line-buffered
        printed = snapshot.content
      }
      print()

      let usage = session.usage
      print(
        "— \(usage.input.totalTokenCount) tokens in"
          + " (\(usage.input.cachedTokenCount) cached),"
          + " \(usage.output.totalTokenCount) out"
      )
    } catch ClaudeError.missingCredential {
      // Provider errors with no LanguageModelError equivalent surface as
      // ClaudeError — this one means "send the user to key entry".
      fail("No usable Claude credential. Check ANTHROPIC_API_KEY.")
    } catch let error as LanguageModelError {
      // The framework's typed errors. Pattern-match the cases your product
      // recovers from; the rest carry a debugDescription worth logging.
      switch error {
      case .rateLimited(let details):
        let until = details.resetDate.map { " until \($0.formatted())" } ?? ""
        fail("Rate limited\(until). Try again later.")
      case .contextSizeExceeded:
        fail("The conversation no longer fits the model's context window.")
      default:
        fail(error.localizedDescription)
      }
    } catch {
      // Transport errors and anything else.
      fail("\(error)")
    }
  }
}

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}
