// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

@Suite struct RequestBuilderTests {
  @Test func `instructions become the system prompt`() throws {
    let transcript = Transcript(entries: [
      .instructions(.init(segments: [.text(.init(content: "Be concise."))], toolDefinitions: [])),
      .prompt(.init(segments: [.text(.init(content: "Hello"))])),
    ])
    let built = try RequestBuilder.build(
      from: .make(transcript: transcript),
      model: .sonnet4_6
    )
    #expect(built.request.system == "Be concise.")
    #expect(built.request.messages.count == 1)
    #expect(built.request.messages[0].role == .user)
    #expect(built.request.messages[0].content == [.text("Hello")])
  }

  @Test func `multi-turn entries map to alternating messages`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Hi"))])),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "Hello!"))])),
      .prompt(.init(segments: [.text(.init(content: "What's the weather?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.map(\.role) == [.user, .assistant, .user])
  }

  @Test func `tool calls and outputs round-trip`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Weather in SF?"))])),
      .toolCalls(
        .init(
          id: "tc1",
          [
            .init(
              id: "call_1",
              toolName: "getWeather",
              arguments: try GeneratedContent(json: #"{"city":"SF"}"#)
            )
          ]
        )
      ),
      .toolOutput(
        .init(
          id: "call_1",
          toolName: "getWeather",
          segments: [.text(.init(content: "72F sunny"))]
        )
      ),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.count == 3)
    #expect(built.request.messages[1].role == .assistant)
    guard case .toolUse(let id, let name, let input) = built.request.messages[1].content[0] else {
      Issue.record("expected toolUse")
      return
    }
    #expect(id == "call_1")
    #expect(name == "getWeather")
    #expect(input == .object(["city": .string("SF")]))
    guard case .toolResult(let resultID, let result, _) = built.request.messages[2].content[0]
    else {
      Issue.record("expected toolResult")
      return
    }
    #expect(resultID == "call_1")
    #expect(result == [.text("72F sunny")])
  }

  @Test func `enabled tools become tool definitions with full schema`() throws {
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
      enabledTools: [
        .init(
          name: "getWeather",
          description: "Returns weather.",
          parameters: TestArgs.generationSchema
        )
      ]
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    #expect(built.request.tools?.count == 1)
    #expect(built.request.tools?[0].name == "getWeather")
    #expect(built.isStructured == false)
    // Schema must carry the actual properties, not a vacuous {"type":"object"}.
    guard case .object(let schema) = built.request.tools?[0].inputSchema,
      case .object(let props)? = schema["properties"]
    else {
      Issue.record("expected object schema with properties")
      return
    }
    #expect(props["city"] != nil)
    #expect(schema["required"] == .array([.string("city")]))
  }

  @Test func `schema becomes output_config.format with strict json schema`() throws {
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Plan a trip"))]))
      ]),
      schema: TestArgs.generationSchema
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    #expect(built.isStructured == true)
    // No synthetic tool — constrained decoding via output_config.format.
    #expect(built.request.toolChoice == nil)
    #expect(built.request.tools == nil)
    // Compatible with thinking, unlike forced tool_use.
    #expect(built.request.thinking == .adaptive(display: .summarized))
    let format = try #require(built.request.outputConfig?.format)
    guard case .object(let schema) = format.schema,
      case .object(let props)? = schema["properties"]
    else {
      Issue.record("expected object schema with properties")
      return
    }
    #expect(props["city"] != nil)
    // Apple-internal extension keys would 400 the API's strict validator.
    #expect(schema["x-order"] == nil)
    #expect(schema["title"] == nil)
    // The API requires additionalProperties: false on every object.
    #expect(schema["additionalProperties"] == .bool(false))
  }

  @Test func `nested schemas are sanitized recursively`() throws {
    // NestedArgs has a nested @Generable, which encodes nested x-order keys.
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ]),
      schema: NestedArgs.generationSchema
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    let format = try #require(built.request.outputConfig?.format)
    let data = try JSONEncoder().encode(format.schema)
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("x-order"))
    #expect(!json.contains(#""title":"#))
    // Property names survive — they're arbitrary, not schema vocabulary.
    #expect(json.contains(#""inner":"#))
    #expect(json.contains(#""value":"#))
  }

  @Test func `reasoningLevel maps to effort`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .deep
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ]),
      contextOptions: contextOptions
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    #expect(built.request.outputConfig?.effort == .high)
  }

  @Test func `effort is dropped on models that reject it`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .deep
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ]),
      contextOptions: contextOptions
    )
    // Haiku doesn't accept effort — sending it is a hard 400.
    let built = try RequestBuilder.build(from: request, model: .haiku4_5)
    #expect(built.request.outputConfig == nil)
  }

  @Test func `bare default capabilities send only the core request`() throws {
    // Defaults opt into nothing — a custom model with `.init()` must produce
    // a request every Claude model accepts.
    var options = GenerationOptions()
    options.temperature = 0.5
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .deep
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
      generationOptions: options,
      contextOptions: contextOptions
    )
    let built = try RequestBuilder.build(
      from: request,
      model: ClaudeModel(id: "claude-future", capabilities: .init())
    )
    #expect(built.request.thinking == nil)
    #expect(built.request.outputConfig == nil)
    #expect(built.request.temperature == nil)
  }

  @Test func `thinking is omitted on models that reject adaptive thinking`() throws {
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ])
    )
    let model = ClaudeModel(id: "claude-test", capabilities: .init(adaptiveThinking: false))
    let built = try RequestBuilder.build(from: request, model: model)
    #expect(built.request.thinking == nil)
  }

  // Issue #7: on Sonnet 5 and Opus 4.7+ `thinking.display` defaults to
  // omitted — thinking blocks stream with empty text and reasoning entries
  // end up with no segments. Every adaptive-thinking model accepts the field,
  // so summarized display is requested unconditionally.
  @Test func `adaptive thinking always requests summarized display`() throws {
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ])
    )
    for model: ClaudeModel in [.sonnet5, .opus4_8, .opus4_7, .sonnet4_6, .opus4_6] {
      let built = try RequestBuilder.build(from: request, model: model)
      #expect(built.request.thinking == .adaptive(display: .summarized))
    }
  }

  @Test func `a schema on a model without structured output fails loudly`() throws {
    // A schema is a contract, not a hint — dropping it silently would surface
    // later as a decode failure.
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ]),
      schema: TestArgs.generationSchema
    )
    let model = ClaudeModel(id: "claude-test", capabilities: .init(structuredOutput: false))
    #expect(throws: LanguageModelError.self) {
      try RequestBuilder.build(from: request, model: model)
    }
  }

  @Test func `a custom model's declared capabilities drive the request`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .deep
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ]),
      contextOptions: contextOptions
    )
    let model = ClaudeModel(
      id: "claude-future-99",
      capabilities: .init(effortLevels: [.low, .medium, .high, .max])
    )
    let built = try RequestBuilder.build(from: request, model: model)
    #expect(built.request.outputConfig?.effort == .high)
  }

  @Test func `a fixed effort overrides reasoningLevel and reaches the wire`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .light
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ]),
      contextOptions: contextOptions
    )
    let built = try RequestBuilder.build(from: request, model: .opus4_8, fixedEffort: .xhigh)
    #expect(built.request.outputConfig?.effort == .xhigh)
  }

  @Test func `a custom reasoning level naming a Claude effort maps directly`() throws {
    var contextOptions = ContextOptions()
    contextOptions.reasoningLevel = .custom("xhigh")
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "Hi"))]))
      ]),
      contextOptions: contextOptions
    )
    let built = try RequestBuilder.build(from: request, model: .opus4_8)
    #expect(built.request.outputConfig?.effort == .xhigh)
  }

  @Test func `reasoning replays as a thinking block in the same assistant turn`() throws {
    let signature = Data([0xAA, 0xBB])
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Weather in SF?"))])),
      .reasoning(
        .init(segments: [.text(.init(content: "I should check."))], signature: signature)
      ),
      .toolCalls(
        .init([
          .init(
            id: "call_1",
            toolName: "getWeather",
            arguments: try GeneratedContent(json: #"{"city":"SF"}"#)
          )
        ])
      ),
      .toolOutput(
        .init(id: "call_1", toolName: "getWeather", segments: [.text(.init(content: "72F"))])
      ),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    // Reasoning and tool calls are separate transcript entries but must land
    // in one assistant message: thinking first, then tool_use.
    #expect(built.request.messages.map(\.role) == [.user, .assistant, .user])
    let assistant = built.request.messages[1]
    guard case .thinking(let thought, let sig) = assistant.content[0] else {
      Issue.record("expected thinking block first, got \(assistant.content)")
      return
    }
    #expect(thought == "I should check.")
    #expect(sig == signature.base64EncodedString())
    guard case .toolUse(let id, _, _) = assistant.content[1] else {
      Issue.record("expected toolUse after thinking, got \(assistant.content)")
      return
    }
    #expect(id == "call_1")
  }

  @Test func `required tool calling maps to tool_choice any and drops thinking`() throws {
    // The API rejects thinking alongside forced tool use; the forced call is
    // the contract, so thinking yields.
    var options = GenerationOptions()
    options.toolCallingMode = .required
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
      enabledTools: [
        .init(name: "getWeather", description: "Weather.", parameters: TestArgs.generationSchema)
      ],
      generationOptions: options
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    #expect(built.request.toolChoice == .any)
    #expect(built.request.thinking == nil)
  }

  @Test func `disallowed tool calling maps to tool_choice none and keeps thinking`() throws {
    var options = GenerationOptions()
    options.toolCallingMode = .disallowed
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
      enabledTools: [
        .init(name: "getWeather", description: "Weather.", parameters: TestArgs.generationSchema)
      ],
      generationOptions: options
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    #expect(built.request.toolChoice == ToolChoice.none)
    #expect(built.request.thinking == .adaptive(display: .summarized))
  }

  @Test func `sampling flows on models without thinking`() throws {
    var options = GenerationOptions()
    options.temperature = 0.5
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
      generationOptions: options
    )
    // Haiku takes sampling params and no adaptive thinking.
    let built = try RequestBuilder.build(from: request, model: .haiku4_5)
    #expect(built.request.temperature == 0.5)
  }

  @Test func `sampling modes map to their wire parameters`() throws {
    func built(_ mode: GenerationOptions.SamplingMode) throws -> MessagesRequest {
      var options = GenerationOptions()
      options.samplingMode = mode
      let request = LanguageModelExecutorGenerationRequest.make(
        transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
        generationOptions: options
      )
      return try RequestBuilder.build(from: request, model: .haiku4_5).request
    }
    #expect(try built(.greedy).temperature == 0)
    #expect(try built(.random(top: 5)).topK == 5)
    #expect(try built(.random(probabilityThreshold: 0.9)).topP == 0.9)
  }

  @Test func `sampling is dropped when thinking is on`() throws {
    // Sampling is withheld on thinking requests — the docs don't promise
    // the 4.6 generation accepts it alongside thinking — sampling
    // is a hint, thinking wins.
    var options = GenerationOptions()
    options.temperature = 0.5
    options.samplingMode = .random(top: 5)
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
      generationOptions: options
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    #expect(built.request.thinking == .adaptive(display: .summarized))
    #expect(built.request.temperature == nil)
    #expect(built.request.topK == nil)
  }

  // An unmarked signature-only entry is a thinking block whose display was
  // omitted, not a redacted thought — the API wants it echoed as received.
  @Test func `unmarked signature-only reasoning replays as an empty thinking block`() throws {
    let signature = Data([0x01, 0x02, 0x03])
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Hi"))])),
      .reasoning(.init(segments: [], signature: signature)),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "Done."))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    let assistant = built.request.messages[1]
    #expect(assistant.content[0] == .thinking("", signature: signature.base64EncodedString()))
    #expect(assistant.content[1] == .text("Done."))
  }

  @Test func `multi-segment reasoning replays without injected separators`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Hi"))])),
      .reasoning(
        .init(
          segments: [.text(.init(content: "part one, ")), .text(.init(content: "part two"))],
          signature: Data([0x01])
        )
      ),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "Done."))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet5)
    #expect(
      built.request.messages[1].content[0]
        == .thinking("part one, part two", signature: Data([0x01]).base64EncodedString())
    )
  }

  @Test func `server tool segments replay as server tool wire blocks`() throws {
    let activity = ClaudeServerToolSegment(
      id: "srv_1",
      content: .webSearch(
        .init(
          query: "weather",
          outcome: .results([
            .init(
              url: URL(string: "https://weather.gov")!,
              title: "NWS",
              encryptedContent: "opaque-token"
            )
          ])
        )
      )
    )
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Weather?"))])),
      .response(
        .init(
          assetIDs: [],
          segments: [.custom(activity), .text(.init(content: "Sunny."))]
        )
      ),
      .prompt(.init(segments: [.text(.init(content: "And tomorrow?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    let assistant = built.request.messages[1]
    #expect(
      assistant.content[0]
        == .serverToolUse(id: "srv_1", name: "web_search", input: .object(["query": "weather"]))
    )
    // The result replays with its opaque citation token intact.
    #expect(
      assistant.content[1]
        == .serverToolResult(
          toolUseID: "srv_1",
          type: "web_search_tool_result",
          content: .array([
            .object([
              "type": "web_search_result",
              "url": "https://weather.gov",
              "title": "NWS",
              "encrypted_content": "opaque-token",
            ])
          ])
        )
    )
    #expect(assistant.content[2] == .text("Sunny."))
  }

  @Test func `an in-flight server tool round trip replays as nothing`() throws {
    // The API hard-rejects an unpaired server_tool_use; a call whose result
    // never arrived (cancelled turn) must not wedge later requests.
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Weather?"))])),
      .response(
        .init(
          assetIDs: [],
          segments: [
            .custom(ClaudeServerToolSegment(id: "srv_1", content: .webSearch(.init(query: "q")))),
            .text(.init(content: "Working on it…")),
          ]
        )
      ),
      .prompt(.init(segments: [.text(.init(content: "Still there?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content == [.text("Working on it…")])
  }

  @Test func `reasoning is not replayed when forced tool use disables thinking`() throws {
    var options = GenerationOptions()
    options.toolCallingMode = .required
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Hi"))])),
      .reasoning(.init(segments: [.text(.init(content: "thinking…"))], signature: Data([1]))),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "Hello."))])),
      .prompt(.init(segments: [.text(.init(content: "Search now"))])),
    ])
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: transcript,
      enabledTools: [
        .init(name: "getWeather", description: "Weather.", parameters: TestArgs.generationSchema)
      ],
      generationOptions: options
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    // The request carries no thinking, so prior thinking blocks must not
    // appear — the API rejects them when thinking is off.
    #expect(built.request.thinking == nil)
    #expect(built.request.messages[1].content == [.text("Hello.")])
  }

  @Test func `a marked redacted entry replays as redacted_thinking even with text`() throws {
    let payload = Data([0xAA])
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Hi"))])),
      .reasoning(
        .init(
          metadata: [redactedThinkingMetadataKey: true],
          segments: [.text(.init(content: "partial summary"))],
          signature: payload
        )
      ),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "Done."))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content[0] == .redactedThinking(payload))
  }

  @Test func `server tool content survives a Codable round trip`() throws {
    // The framework persists custom segments via Codable; every case must
    // round-trip without losing replay-critical fields.
    let cases: [ClaudeServerToolSegment.Content] = [
      .webSearch(.init(query: "weather")),
      .webSearch(
        .init(
          query: "weather",
          outcome: .results([
            .init(
              url: URL(string: "https://weather.gov")!,
              title: "NWS",
              pageAge: "June 7, 2026",
              encryptedContent: "opaque"
            )
          ])
        )
      ),
      .webSearch(.init(query: "weather", outcome: .failure(errorCode: "max_uses_exceeded"))),
      .webFetch(.init(url: URL(string: "https://example.com")!)),
      .webFetch(
        .init(
          url: URL(string: "https://example.com")!,
          outcome: .document(
            .init(
              url: URL(string: "https://example.com")!,
              title: "Example",
              text: "JVBERi0xLjc=",
              mediaType: "application/pdf",
              retrievedAt: "2026-06-08T00:00:00Z"
            )
          )
        )
      ),
      .codeExecution(.init(code: "print(1)")),
      .codeExecution(
        .init(
          code: "print(1)",
          outcome: .output(.init(stdout: "1\n", stderr: "", returnCode: 0))
        )
      ),
      .codeExecution(.init(code: "print(1)", outcome: .failure(errorCode: "unavailable"))),
      .unrecognized(
        .init(
          toolName: "future_tool",
          callJSON: #"{"x":1}"#,
          resultType: "future_tool_result",
          resultJSON: "[]"
        )
      ),
    ]
    for content in cases {
      let data = try JSONEncoder().encode(content)
      let decoded = try JSONDecoder()
        .decode(
          ClaudeServerToolSegment.Content.self,
          from: data
        )
      #expect(decoded == content, "round trip changed \(content)")
    }
  }

  @Test func `prompt images in history become image blocks`() throws {
    let transcript = Transcript(entries: [
      .prompt(
        .init(segments: [
          .text(.init(content: "What is this?")),
          .attachment(.init(content: .image(.init(makeTestImage())))),
        ])
      ),
      .response(.init(assetIDs: [], segments: [.text(.init(content: "A red square."))])),
      .prompt(.init(segments: [.text(.init(content: "What color?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.count == 3)
    guard case .image(let source) = built.request.messages[0].content[1] else {
      Issue.record("expected image block in prior prompt, got \(built.request.messages[0].content)")
      return
    }
    #expect(source.mediaType == "image/jpeg")
    #expect(!source.data.isEmpty)
  }

  @Test func `tool output images become image blocks in the tool result`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Screenshot the page"))])),
      .toolCalls(
        .init([
          .init(id: "call_1", toolName: "screenshot", arguments: try GeneratedContent(json: "{}"))
        ])
      ),
      .toolOutput(
        .init(
          id: "call_1",
          toolName: "screenshot",
          segments: [
            .text(.init(content: "Captured.")),
            .attachment(.init(content: .image(.init(makeTestImage())))),
          ]
        )
      ),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    guard case .toolResult(_, let content, _) = built.request.messages[2].content[0] else {
      Issue.record("expected toolResult")
      return
    }
    #expect(content.count == 2)
    #expect(content[0] == .text("Captured."))
    guard case .image = content[1] else {
      Issue.record("expected image block in tool result, got \(content)")
      return
    }
  }

  @Test func `maximumResponseTokens maps to max_tokens`() throws {
    var options = GenerationOptions()
    options.maximumResponseTokens = 512
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))]),
      generationOptions: options
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    #expect(built.request.maxTokens == 512)
  }

  @Test func `an empty allowlist fails closed by omitting the tool`() throws {
    // `.allowing([])` permits no domain; the wire can't express that, so the
    // tool is dropped rather than silently becoming unrestricted.
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Hi"))]))])
    )
    let built = try RequestBuilder.build(
      from: request,
      model: .sonnet4_6,
      serverTools: [.webSearch(domains: .allowing([])), .webFetch(domains: .blocking([]))]
    )
    // Search is omitted; fetch (blocking nothing = unrestricted) survives
    // with no domain field.
    #expect(built.request.tools?.count == 1)
    #expect(built.request.tools?[0].name == "web_fetch")
    #expect(built.request.tools?[0].config["blocked_domains"] == nil)
  }

  @Test func `server tools encode with versioned type and flat config`() throws {
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "Search"))]))]
      ),
      enabledTools: [
        .init(
          name: "getWeather",
          description: "Returns weather.",
          parameters: TestArgs.generationSchema
        )
      ]
    )
    let built = try RequestBuilder.build(
      from: request,
      model: .sonnet4_6,
      serverTools: [.webSearch(domains: .allowing(["weather.gov"]), maxUses: 3), .codeExecution]
    )
    let data = try JSONEncoder().encode(built.request)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 3)

    // Custom tool: name + description + input_schema, no `type`.
    let custom = try #require(tools.first { $0["name"] as? String == "getWeather" })
    #expect(custom["type"] == nil)
    #expect(custom["input_schema"] != nil)

    // Server tool: versioned `type` + name + flat config, no `input_schema`.
    let search = try #require(tools.first { $0["name"] as? String == "web_search" })
    #expect(search["type"] as? String == "web_search_20260209")
    #expect(search["allowed_domains"] as? [String] == ["weather.gov"])
    #expect(search["max_uses"] as? Int == 3)
    #expect(search["input_schema"] == nil)

    let exec = try #require(tools.first { $0["name"] as? String == "code_execution" })
    #expect(exec["type"] as? String == "code_execution_20260120")
  }
}

@Generable
private struct TestArgs {
  var city: String
}

@Generable
private struct NestedArgs {
  var inner: NestedInner
}

@Generable
private struct NestedInner {
  var value: String
}
