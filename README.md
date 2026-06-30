# Claude for Foundation Models

Use Claude as a server-side language model through Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework. The package conforms Claude to the framework's `LanguageModel` protocol, so you drive it with the same `LanguageModelSession` API you use for Apple's on-device model — `respond(to:)`, streaming, guided generation, and tool calling all work the same way.

> **Beta.** This package targets the Foundation Models server-side language model API introduced in the OS 27 betas. APIs may change before general availability.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Example](#example)
- [Choosing a model](#choosing-a-model)
- [Authentication](#authentication)
- [Streaming](#streaming)
- [Structured output](#structured-output)
- [Server-side tools](#server-side-tools)
- [Error handling](#error-handling)
- [What this package provides](#what-this-package-provides)
- [Support](#support)
- [License](#license)

## Requirements

- iOS 27, macOS 27, visionOS 27, or watchOS 27 (beta) — the OS releases whose Foundation Models framework supports server-side language models.
- Xcode 27 (beta).
- An Anthropic API key for development. See [Authentication](#authentication) for production options.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/anthropics/ClaudeForFoundationModels.git", from: "0.1.0")
]
```

Or in Xcode: **File ▸ Add Package Dependencies…** and enter the repository URL.

Then add `ClaudeForFoundationModels` to your target's dependencies and import it alongside `FoundationModels`:

```swift
import FoundationModels
import ClaudeForFoundationModels
```

## Quick start

```swift
import FoundationModels
import ClaudeForFoundationModels

let model = ClaudeLanguageModel(
  name: .sonnet5,
  auth: .apiKey(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
)

let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Plan a 4-day trip to Buenos Aires.")
print(response.content)
```

`ClaudeLanguageModel` is the entry point. Pass it to `LanguageModelSession` and use the session exactly as you would with any Foundation Models provider.

## Example

[`Examples/ClaudeExample`](Examples/ClaudeExample) is a runnable command-line target that streams one chat turn through `LanguageModelSession` to the terminal, with token usage at the end (running it requires a macOS 27 host):

```sh
ANTHROPIC_API_KEY=<key> swift run ClaudeExample "What should I see in Kyoto?"
```

Pass `--search` to enable server-side web search for the turn:

```sh
ANTHROPIC_API_KEY=<key> swift run ClaudeExample --search "Top spaceflight news this week?"
```

## Choosing a model

Model identifiers are values of `ClaudeModel`. Use a compiled-in constant, or construct one with explicit capabilities for an ID that isn't compiled in yet (see [Capabilities](#capabilities)):

```swift
ClaudeLanguageModel(name: .opus4_8, auth: auth)
```

Constants mirror API model IDs (`.opus4_8` is `claude-opus-4-8`) and carry each model's capabilities. New models ship as new constants in package releases.

Dateless model IDs like `claude-opus-4-8` (the 4.6 generation onward) are pinned snapshots, not evergreen pointers — the model behind an ID doesn't change underneath you.

### Capabilities

Each model declares what it accepts — sampling parameters, effort levels, adaptive thinking, structured output, and image input. The bridge uses this to decide which request fields to send, since sending a field a model rejects is a hard error. The constants carry the right capabilities. For an ID that isn't compiled in, declare what the model accepts:

```swift
let model = ClaudeModel(
  id: "claude-experimental-x",
  capabilities: .init(effortLevels: [.low, .high], structuredOutput: true)
)
ClaudeLanguageModel(name: model, auth: auth)
```

### Effort

Pin a Claude effort level for every request with `fixedEffort:`. It takes precedence over the framework's per-request reasoning hints. The API defaults to `high` when no effort is sent:

```swift
ClaudeLanguageModel(name: .opus4_8, auth: auth, fixedEffort: .xhigh)
```

The framework's reasoning levels map to effort per request: `.light` → `low`, `.moderate` → `medium`, `.deep` → `high`, and `.custom` accepts a Claude effort name directly (`"xhigh"`, `"max"`). Levels a model doesn't accept are dropped — a reasoning level is a hint, not a contract.

The level must be one the model accepts — each model declares which of the five levels (`low`, `medium`, `high`, `xhigh`, `max`) it takes.

## Authentication

Set the credential with the `auth:` parameter.

```swift
// Development. A bundled key is extractable from a shipping app — use one of
// the production options below before release.
ClaudeLanguageModel(name: .sonnet5, auth: .apiKey("..."))

// Production via your own backend. The relay at `baseURL` adds the credential
// server-side; the app ships no key. `headers` are sent on every request so the
// proxy can authorize the caller — pass `[:]` if it needs none.
ClaudeLanguageModel(
  name: .sonnet5,
  auth: .proxied(headers: ["X-App-Token": "..."]),
  baseURL: URL(string: "https://api.yourapp.com/claude")!
)
```

**Coming soon:** a production mode that doesn't require running your own backend — each app install authenticates with App Attest and usage is billed to your Anthropic workspace. Until that ships, use `.apiKey` for development and `.proxied` for production.

## Streaming

`streamResponse(to:)` returns the response incrementally. Each element is a cumulative snapshot:

```swift
let stream = session.streamResponse(to: "Summarize today's top science stories.")
for try await partial in stream {
  print(partial.content)
}
```

## Structured output

Annotate a type with `@Generable` and request it with `generating:`. The model returns a value of that type:

```swift
@Generable
struct Trip {
  @Guide(description: "Destination city") var destination: String
  @Guide(description: "Length in days") var days: Int
}

let response = try await session.respond(to: "Plan a trip to Tokyo.", generating: Trip.self)
print(response.content.destination)
```

Structured output requires a model whose capabilities include it (all compiled-in constants do).

## Server-side tools

Server-side tools run on Anthropic's infrastructure within a single round-trip — web search, web fetch, and code execution. Configure them per model with `serverTools:`:

```swift
let model = ClaudeLanguageModel(
  name: .sonnet5,
  auth: auth,
  serverTools: [
    .webSearch(maxUses: 5),
    .codeExecution,
  ]
)
```

`.webSearch` and `.webFetch` accept a `domains:` filter — `.unrestricted` (the default), `.allowing([...])`, or `.blocking([...])` — and an optional `maxUses`. These are distinct from the framework's `tools:` array, which holds client-side tools the framework invokes on the device.

## Error handling

Provider errors that don't map onto a Foundation Models `LanguageModelError` surface as `ClaudeError`. Pattern-match to drive product flows:

```swift
do {
  let response = try await session.respond(to: prompt)
  print(response.content)
} catch ClaudeError.missingCredential {
  // Prompt for an API key.
} catch {
  // Foundation Models errors (guardrails, context length, decoding) and transport errors.
}
```

## What this package provides

The public surface is Apple's Foundation Models provider conformance plus the configuration types that reach it — `ClaudeLanguageModel`, `ClaudeModel`, `AuthMode`, and `ClaudeServerTool`. It is not a general-purpose Anthropic Messages API client.

## Support

**Maintenance status:** maintained on a best-effort basis, provided as is, and not accepting external contributions.

Bug reports and feedback are welcome — please [open an issue](../../issues). We triage issues and address them on a best-effort basis.

## License

Apache 2.0 — see [LICENSE](LICENSE).

Copyright 2026 Anthropic PBC
