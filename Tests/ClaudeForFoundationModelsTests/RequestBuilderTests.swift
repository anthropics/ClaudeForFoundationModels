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

  @Test func `tool call arguments replay with every JSON shape intact`() throws {
    let arguments = try GeneratedContent(
      json: #"{"n":1.5,"i":2,"b":true,"s":"x","a":[1,"y",null],"o":{"k":{}}}"#
    )
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      .toolCalls(.init([.init(id: "call_1", toolName: "t", arguments: arguments)])),
      .toolOutput(.init(id: "call_1", toolName: "t", segments: [.text(.init(content: "ok"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(
      built.request.messages[1].content == [
        .toolUse(
          id: "call_1",
          name: "t",
          input: ["n": 1.5, "i": 2, "b": true, "s": "x", "a": [1, "y", nil], "o": ["k": [:]]]
        )
      ]
    )
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

  // A signature-only entry is a thinking block whose display was omitted;
  // the API wants it echoed as received.
  @Test func `signature-only reasoning replays as an empty thinking block`() throws {
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

  @Test func `a recorded turn replays as its blocks in the order they were received`() throws {
    let blocks: [JSONValue] = [
      ["type": "text", "text": "Let me check."],
      serverToolUse(id: "srv_1", name: "web_search", input: ["query": "weather"]),
      [
        "type": "web_search_tool_result", "tool_use_id": "srv_1",
        "content": [["type": "web_search_result", "encrypted_content": "opaque-token"]],
      ],
      ["type": "text", "text": "\n\n"],
      [
        "type": "text", "text": "Sunny.",
        "citations": [["type": "web_search_result_location", "encrypted_index": "idx"]],
      ],
    ]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Weather?"))])),
      recordedResponse(blocks),
      .prompt(.init(segments: [.text(.init(content: "And tomorrow?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content == blocks.map(ContentBlock.raw))
  }

  @Test func `blocks recorded across the turn's entries replay in the order they were sent`()
    throws
  {
    // Thinking interleaved with a search, then a client tool call: four
    // entries, one assistant message, wire order restored from positions
    // even though the response entry (created by the search) precedes the
    // second reasoning entry in the transcript.
    let thought1: JSONValue = ["type": "thinking", "thinking": "hm", "signature": "c2ln"]
    let search = serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"])
    let result: JSONValue = [
      "type": "web_search_tool_result", "tool_use_id": "srv_1", "content": [],
    ]
    let thought2: JSONValue = ["type": "redacted_thinking", "data": "3q2+7w=="]
    let call: JSONValue = ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedReasoning(thought1, at: 0),
      recordedResponse([search, result], from: 1),
      recordedReasoning(thought2, at: 3),
      try recordedToolCall(call, at: 4),
      .toolOutput(
        .init(id: "toolu_1", toolName: "ping", segments: [.text(.init(content: "pong"))])
      ),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.map(\.role) == [.user, .assistant, .user])
    #expect(
      built.request.messages[1].content
        == [thought1, search, result, thought2, call].map(ContentBlock.raw)
    )
  }

  @Test func `entries with no record are rebuilt from what the framework holds`() throws {
    // History the app assembled around one recorded response: nothing may
    // vanish, and the rebuilt entries keep their place relative to it.
    let search = serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"])
    let result: JSONValue = [
      "type": "web_search_tool_result", "tool_use_id": "srv_1", "content": [],
    ]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      .reasoning(.init(segments: [.text(.init(content: "first"))], signature: Data([0x01]))),
      .response(.init(segments: [.text(.init(content: "Earlier answer."))])),
      recordedResponse([search, result]),
      .toolCalls(
        .init([.init(id: "toolu_1", toolName: "ping", arguments: try GeneratedContent(json: "{}"))])
      ),
      .toolOutput(
        .init(id: "toolu_1", toolName: "ping", segments: [.text(.init(content: "pong"))])
      ),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(
      built.request.messages[1].content == [
        .thinking("first", signature: Data([0x01]).base64EncodedString()),
        .text("Earlier answer."),
        .raw(search), .raw(result),
        .toolUse(id: "toolu_1", name: "ping", input: [:]),
      ]
    )
  }

  @Test func `recorded thinking is withheld when the request doesn't enable thinking`() throws {
    var options = GenerationOptions()
    options.toolCallingMode = .required
    let search = serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"])
    let result: JSONValue = [
      "type": "web_search_tool_result", "tool_use_id": "srv_1", "content": [],
    ]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedReasoning(["type": "thinking", "thinking": "hm", "signature": "c2ln"], at: 0),
      recordedReasoning(["type": "redacted_thinking", "data": "AAAA"], at: 1),
      recordedResponse([search, result], from: 2),
      .prompt(.init(segments: [.text(.init(content: "again"))])),
    ])
    let request = LanguageModelExecutorGenerationRequest.make(
      transcript: transcript,
      enabledTools: [
        .init(name: "ping", description: "Pings.", parameters: TestArgs.generationSchema)
      ],
      generationOptions: options
    )
    let built = try RequestBuilder.build(from: request, model: .sonnet4_6)
    #expect(built.request.thinking == nil)
    #expect(built.request.messages[1].content == [.raw(search), .raw(result)])
  }

  @Test func `a call whose result never arrived replays as nothing`() throws {
    // The API rejects an unanswered server_tool_use once the turn is over; a
    // turn cut off mid-search must not wedge every later request.
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Weather?"))])),
      recordedResponse([
        ["type": "text", "text": "Working on it…"],
        serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"]),
      ]),
      .prompt(.init(segments: [.text(.init(content: "Still there?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(
      built.request.messages[1].content == [.raw(["type": "text", "text": "Working on it…"])]
    )
  }

  @Test func `a client tool call that never got its output replays as nothing`() throws {
    // Stopped while the tool was running: the call is on the transcript, its
    // output never will be, and the API rejects a tool_use with no result.
    let call: JSONValue = ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([["type": "text", "text": "On it."]]),
      try recordedToolCall(call, at: 1),
      .toolCalls(
        .init([.init(id: "toolu_2", toolName: "ping", arguments: try GeneratedContent(json: "{}"))])
      ),
      .prompt(.init(segments: [.text(.init(content: "never mind"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content == [.raw(["type": "text", "text": "On it."])])
  }

  @Test func `a call answered in a later turn replays in both turns`() throws {
    // Server and client tools called together: the result comes back in the
    // response that follows the client tool's output.
    let call = serverToolUse(id: "srv_1", name: "web_fetch", input: ["url": "https://a.example"])
    let toolUse: JSONValue = ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]]
    let result: JSONValue = [
      "type": "web_fetch_tool_result", "tool_use_id": "srv_1", "content": [:],
    ]
    let answer: JSONValue = ["type": "text", "text": "Both done."]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([call]),
      try recordedToolCall(toolUse, at: 1),
      .toolOutput(
        .init(id: "toolu_1", toolName: "ping", segments: [.text(.init(content: "pong"))])
      ),
      recordedResponse([result, answer]),
      .prompt(.init(segments: [.text(.init(content: "thanks"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.map(\.role) == [.user, .assistant, .user, .assistant, .user])
    #expect(built.request.messages[1].content == [.raw(call), .raw(toolUse)])
    #expect(built.request.messages[3].content == [.raw(result), .raw(answer)])
  }

  @Test func `text that streamed past the last recorded block replays as a trailing text block`()
    throws
  {
    let lead: JSONValue = ["type": "text", "text": "Checking. "]
    let call = serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"])
    let result: JSONValue = [
      "type": "web_search_tool_result", "tool_use_id": "srv_1", "content": [],
    ]
    func build(segments: [String]) throws -> [ContentBlock] {
      let transcript = Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "go"))])),
        .response(
          .init(
            metadata: record([lead, call, result]).metadata,
            segments: segments.map { .text(.init(content: $0)) }
          )
        ),
        .prompt(.init(segments: [.text(.init(content: "and?"))])),
      ])
      return try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
        .request.messages[1].content
    }

    // Stopped mid-answer: the record ends at the result, the segments go on.
    #expect(
      try build(segments: ["Checking. ", "It is su"])
        == [.raw(lead), .raw(call), .raw(result), .text("It is su")]
    )
    // Completed normally: one segment per recorded text block, nothing more.
    #expect(try build(segments: ["Checking. "]) == [.raw(lead), .raw(call), .raw(result)])
    // A trailing segment with nothing visible in it isn't worth a block.
    #expect(try build(segments: ["Checking. ", "\n\n"]) == [.raw(lead), .raw(call), .raw(result)])
  }

  @Test func `an unsigned thought is not replayed`() throws {
    // Generation stopped during the thinking that followed a search: the
    // reasoning entry exists but its block never completed.
    let recorded: [JSONValue] = [
      serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"]),
      ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": []],
    ]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse(recorded),
      .reasoning(.init(segments: [.text(.init(content: "so far"))])),
      .prompt(.init(segments: [.text(.init(content: "and?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content == recorded.map(ContentBlock.raw))
  }

  @Test func `a recorded thought replays verbatim, redacted or not`() throws {
    let redacted: JSONValue = ["type": "redacted_thinking", "data": "3q2+7w=="]
    let omitted: JSONValue = ["type": "thinking", "thinking": "", "signature": "c2ln"]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "Hi"))])),
      recordedReasoning(redacted, at: 0),
      recordedReasoning(omitted, at: 1),
      recordedResponse([["type": "text", "text": "Done."]], from: 2),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(
      built.request.messages[1].content
        == [.raw(redacted), .raw(omitted), .raw(["type": "text", "text": "Done."])]
    )
  }

  @Test func `a turn pruned down to its thoughts replays as nothing`() throws {
    // The tool never returned (stopped while it ran): the call goes, and a
    // message of thinking alone isn't worth sending.
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedReasoning(["type": "thinking", "thinking": "hm", "signature": "c2ln"], at: 0),
      try recordedToolCall(
        ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]],
        at: 1
      ),
      .prompt(.init(segments: [.text(.init(content: "never mind"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.map(\.role) == [.user])
  }

  @Test func `a tool output whose call is gone from history replays as nothing`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      .toolOutput(
        .init(id: "toolu_gone", toolName: "ping", segments: [.text(.init(content: "pong"))])
      ),
      .response(.init(segments: [.text(.init(content: "Done."))])),
      .prompt(.init(segments: [.text(.init(content: "and?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.map(\.role) == [.user, .assistant, .user])
    #expect(built.request.messages[1].content == [.text("Done.")])
  }

  @Test func `recorded responses from separate turns left adjacent replay one after the other`()
    throws
  {
    // The prompt between them was removed from history; each record counts
    // positions from zero within its own turn.
    let search = serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"])
    let result: JSONValue = [
      "type": "web_search_tool_result", "tool_use_id": "srv_1", "content": [],
    ]
    let first: JSONValue = ["type": "text", "text": "First."]
    let second: JSONValue = ["type": "text", "text": "Second."]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([search, result, first]),
      recordedResponse([second], turn: "turn-2"),
      .prompt(.init(segments: [.text(.init(content: "and?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(
      built.request.messages[1].content == [search, result, first, second].map(ContentBlock.raw)
    )
  }

  @Test func `any tool_use and tool_result block family pairs up by id`() throws {
    // Pairing follows the API's block naming, so tools this package doesn't
    // know about (say, ones a proxy backend adds) get the same protection.
    let call: JSONValue = ["type": "future_tool_use", "id": "f_1", "name": "future", "input": [:]]
    let result: JSONValue = ["type": "future_tool_result", "tool_use_id": "f_1", "content": [:]]
    let orphanResult: JSONValue = [
      "type": "future_tool_result", "tool_use_id": "f_gone", "content": [:],
    ]
    let unansweredCall: JSONValue = [
      "type": "future_tool_use", "id": "f_2", "name": "future", "input": [:],
    ]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([call, result, orphanResult, unansweredCall]),
      .prompt(.init(segments: [.text(.init(content: "and?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content == [.raw(call), .raw(result)])
  }

  @Test func `returning a client tool's output keeps the turn's unanswered call`() throws {
    // The API runs the deferred server tool when it receives this request,
    // so the call has to be there even though nothing answers it yet.
    let call = serverToolUse(id: "srv_1", name: "web_fetch", input: ["url": "https://a.example"])
    let toolUse: JSONValue = ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([call]),
      try recordedToolCall(toolUse, at: 1),
      .toolOutput(
        .init(id: "toolu_1", toolName: "ping", segments: [.text(.init(content: "pong"))])
      ),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content == [.raw(call), .raw(toolUse)])
  }

  @Test func `an unanswered call is dropped once the conversation has moved on`() throws {
    // The continuation never happened (say, cancelled while the client tool
    // ran); a later user message would end the turn with the call open.
    let call = serverToolUse(id: "srv_1", name: "web_fetch", input: ["url": "https://a.example"])
    let toolUse: JSONValue = ["type": "tool_use", "id": "toolu_1", "name": "ping", "input": [:]]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([call]),
      try recordedToolCall(toolUse, at: 1),
      .toolOutput(
        .init(id: "toolu_1", toolName: "ping", segments: [.text(.init(content: "pong"))])
      ),
      .prompt(.init(segments: [.text(.init(content: "never mind"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content == [.raw(toolUse)])
  }

  @Test func `a result whose call was trimmed from history replays as nothing`() throws {
    let answer: JSONValue = ["type": "text", "text": "Both done."]
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([
        ["type": "web_fetch_tool_result", "tool_use_id": "srv_gone", "content": [:]],
        answer,
      ]),
      .prompt(.init(segments: [.text(.init(content: "thanks"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages[1].content == [.raw(answer)])
  }

  @Test func `a turn with nothing to replay produces no assistant message`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      recordedResponse([serverToolUse(id: "srv_1", name: "web_search", input: ["query": "q"])]),
      .prompt(.init(segments: [.text(.init(content: "hello?"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.map(\.role) == [.user])
    #expect(built.request.messages[0].content == [.text("go"), .text("hello?")])
  }

  @Test func `outputs of parallel tool calls share one user message`() throws {
    let transcript = Transcript(entries: [
      .prompt(.init(segments: [.text(.init(content: "go"))])),
      .toolCalls(
        .init([
          .init(id: "call_1", toolName: "ping", arguments: try GeneratedContent(json: "{}")),
          .init(id: "call_2", toolName: "ping", arguments: try GeneratedContent(json: "{}")),
        ])
      ),
      .toolOutput(.init(id: "call_1", toolName: "ping", segments: [.text(.init(content: "a"))])),
      .toolOutput(.init(id: "call_2", toolName: "ping", segments: [.text(.init(content: "b"))])),
    ])
    let built = try RequestBuilder.build(from: .make(transcript: transcript), model: .sonnet4_6)
    #expect(built.request.messages.map(\.role) == [.user, .assistant, .user])
    #expect(
      built.request.messages[2].content == [
        .toolResult(toolUseID: "call_1", content: [.text("a")]),
        .toolResult(toolUseID: "call_2", content: [.text("b")]),
      ]
    )
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
