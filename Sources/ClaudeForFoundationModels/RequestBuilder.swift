// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import FoundationModels

/// Pure translation: framework request → Messages API request body.
enum RequestBuilder {
  struct Built {
    var request: MessagesRequest
    /// True when `schema` was forwarded as `output_config.format` — the
    /// response will be a single text block of schema-conforming JSON rather
    /// than free text.
    var isStructured: Bool
  }

  static func build(
    from request: LanguageModelExecutorGenerationRequest,
    model: ClaudeModel,
    fixedEffort: ClaudeModel.Effort? = nil,
    serverTools: Set<ClaudeServerTool> = []
  ) throws -> Built {
    var system: String?
    var messages: [Message] = []

    // Replayed thinking blocks are only required during tool use with
    // thinking active, and prior-turn thinking may always be omitted — so
    // reasoning entries replay only on requests that send `thinking`.
    let toolChoice = toolChoice(for: request.generationOptions.toolCallingMode)
    // Forced tool use is a contract — the API rejects thinking alongside
    // it, so thinking yields for that request.
    let thinkingConfig = toolChoice == .any ? nil : thinking(for: model)

    for entry in request.transcript {
      switch entry {
      case .instructions(let i):
        system = (system.map { $0 + "\n\n" } ?? "") + text(of: i.segments)

      case .prompt(let p):
        messages.append(.init(role: .user, content: try contentBlocks(from: p.segments)))

      case .reasoning(let r):
        guard thinkingConfig != nil else { continue }
        // Replayed as a thinking block so the API can verify the signature
        // and keep the thought chain intact across tool-use turns. Redacted
        // thoughts (marked by the translator) go back verbatim as
        // redacted_thinking. An unmarked entry with empty text is a thinking
        // block whose display was omitted — it must echo back as received;
        // reshaping it as redacted_thinking corrupts the payload.
        // Thinking text replays as the concatenation it streamed as — an
        // injected separator would modify the block, which the API rejects.
        let thought = text(of: r.segments, separator: "")
        let isRedacted = (r.metadata[redactedThinkingMetadataKey] as? Bool) == true
        let block: ContentBlock =
          if isRedacted, let redacted = r.signature {
            .redactedThinking(redacted)
          } else {
            .thinking(thought, signature: r.signature?.base64EncodedString())
          }
        messages.append(.init(role: .assistant, content: [block]))

      case .toolCalls(let calls):
        let blocks: [ContentBlock] = calls.map {
          .toolUse(
            id: $0.id,
            name: $0.toolName,
            input: jsonValue(from: $0.arguments)
          )
        }
        messages.append(.init(role: .assistant, content: blocks))

      case .toolOutput(let out):
        // Block content, not flattened text — tool results may carry images.
        let blocks = try contentBlocks(from: out.segments)
        messages.append(
          .init(
            role: .user,
            content: [
              .toolResult(
                toolUseID: out.id,
                content: blocks.isEmpty ? [.text("")] : blocks
              )
            ]
          )
        )

      case .response(let r):
        messages.append(.init(role: .assistant, content: try contentBlocks(from: r.segments)))

      @unknown default:
        break
      }
    }

    // The framework records reasoning, tool calls, and response text as
    // separate transcript entries; the API wants them as one assistant turn —
    // on replay a thinking block must sit in the same message as the
    // tool_use blocks it preceded.
    messages = mergingConsecutiveSameRole(messages)

    // Server tools are sorted for a stable wire order — the prompt cache
    // is a prefix match, and `tools` renders first.
    let allTools =
      request.enabledToolDefinitions.map(toolDefinition)
      + serverTools.compactMap(\.toolDefinition).sorted { $0.name < $1.name }
    var req = MessagesRequest(
      model: model.id,
      maxTokens: request.generationOptions.maximumResponseTokens ?? 16_000,
      system: system,
      messages: messages,
      tools: allTools.isEmpty ? nil : allTools,
      toolChoice: toolChoice,
      thinking: thinkingConfig,
      cacheControl: .init(),
      outputConfig: resolvedEffort(
        fixed: fixedEffort,
        options: request.contextOptions,
        model: model
      )
      .map { OutputConfig(effort: $0) },
      stream: true
    )
    applySampling(request.generationOptions, to: &req, model: model)

    let isStructured = request.schema != nil
    if let schema = request.schema {
      // Unlike effort, a schema is a contract, not a hint — without
      // constrained decoding the response may not decode at all, so failing
      // loudly beats silently dropping it.
      guard model.capabilities.structuredOutput else {
        throw LanguageModelError.unsupportedGenerationGuide(
          .init(
            schemaName: nil,
            debugDescription:
              "\(model.id) does not support structured output (output_config.format)."
          )
        )
      }
      applyStructuredOutput(
        schema,
        includeInPrompt: request.contextOptions.includeSchemaInPrompt ?? true,
        to: &req
      )
    }

    return Built(request: req, isStructured: isStructured)
  }

  // MARK: - Schema → JSON Schema

  /// `GenerationSchema` is `Codable` and encodes as JSON Schema, but with
  /// framework-specific extension keys (`x-order`, `title`) the API's strict
  /// validator rejects. Strip non-standard keys recursively. The API also
  /// doesn't enforce `minimum`/`maximum`/`minItems`/`maxItems`/`pattern` —
  /// those are stripped too (the framework validates `@Guide` bounds
  /// client-side after decode).
  static func jsonSchema(from schema: GenerationSchema) -> JSONValue {
    guard let value = JSONValue.encoded(schema) else {
      return .object(["type": "object"])
    }
    return sanitize(value)
  }

  /// Keys the API's strict schema validator accepts. Everything else is
  /// dropped — sending an unknown key is a hard 400.
  private static let allowedSchemaKeys: Set<String> = [
    "type", "properties", "required", "items", "enum", "const",
    "anyOf", "allOf", "oneOf", "$ref", "$defs", "definitions",
    "description", "format", "additionalProperties",
  ]

  /// Keys whose values are `{name: schema}` maps — the names are arbitrary
  /// and must be preserved; only the nested schemas are sanitized.
  private static let mapValuedKeys: Set<String> = ["properties", "$defs", "definitions"]

  private static func sanitize(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let dict):
      var out: [String: JSONValue] = [:]
      for (key, v) in dict where allowedSchemaKeys.contains(key) {
        if mapValuedKeys.contains(key), case .object(let nested) = v {
          out[key] = .object(nested.mapValues(sanitize))
        } else {
          out[key] = sanitize(v)
        }
      }
      // The API requires `additionalProperties: false` on every object.
      if out["type"] == .string("object"), out["additionalProperties"] == nil {
        out["additionalProperties"] = .bool(false)
      }
      return .object(out)
    case .array(let arr):
      return .array(arr.map(sanitize))
    default:
      return value
    }
  }

  // MARK: - Private

  /// Folds consecutive same-role messages into one message with the content
  /// blocks concatenated in order.
  private static func mergingConsecutiveSameRole(_ messages: [Message]) -> [Message] {
    var out: [Message] = []
    for message in messages {
      if out.last?.role == message.role {
        out[out.count - 1].content.append(contentsOf: message.content)
      } else {
        out.append(message)
      }
    }
    return out
  }

  private static func text(of segments: [Transcript.Segment], separator: String = "\n") -> String {
    segments.compactMap {
      switch $0 {
      case .text(let t): t.content
      case .structure(let s): s.content.jsonString
      case .attachment, .custom: nil
      @unknown default: nil
      }
    }
    .joined(separator: separator)
  }

  private static func contentBlocks(from segments: [Transcript.Segment]) throws -> [ContentBlock] {
    try segments.flatMap { segment -> [ContentBlock] in
      switch segment {
      case .text(let t) where !t.content.isEmpty: [.text(t.content)]
      case .text: []
      case .structure(let s): [.text(s.content.jsonString)]
      case .attachment(let a):
        switch a.content {
        case .image(let image):
          [try ClaudeImage(cgImage: image.cgImage, orientation: image.orientation).contentBlock]
        @unknown default: []
        }
      case .custom(let segment):
        customBlocks(from: segment)
      @unknown default: []
      }
    }
  }

  /// Server-tool activity replays as the wire blocks it came from — the API
  /// expects prior `server_tool_use` / `*_tool_result` blocks back (search
  /// results carry encrypted content the model can cite on later turns).
  /// Other custom segments fall back to their text rendering.
  private static func customBlocks(from segment: any Transcript.CustomSegment) -> [ContentBlock] {
    guard let serverTool = segment as? ClaudeServerToolSegment else {
      let text = String(describing: segment)
      return text.isEmpty ? [] : [.text(text)]
    }
    return serverTool.content.wireBlocks(id: serverTool.id)
  }

  private static func toolDefinition(_ def: Transcript.ToolDefinition) -> ToolDefinition {
    ToolDefinition(
      name: def.name,
      description: def.description,
      inputSchema: jsonSchema(from: def.parameters)
    )
  }

  private static func jsonValue(from content: GeneratedContent) -> JSONValue {
    JSONValue.parsed(content.jsonString) ?? .object([:])
  }

  /// Adaptive thinking whenever the model accepts it; omitted otherwise —
  /// sending `thinking` to a model that rejects it is a hard 400. Display is
  /// pinned to summarized: every adaptive-thinking model accepts the field,
  /// Sonnet 5 and Opus 4.7+ default to `omitted` (thinking blocks with empty
  /// text), and display changes visibility only, not billing.
  private static func thinking(for model: ClaudeModel) -> ThinkingConfig? {
    model.capabilities.adaptiveThinking ? .adaptive(display: .summarized) : nil
  }

  private static func resolvedEffort(
    fixed: ClaudeModel.Effort?,
    options: ContextOptions,
    model: ClaudeModel
  ) -> OutputConfig.Effort? {
    // A fixed effort is a contract, not a hint: it wins over the framework's
    // `reasoningLevel` and ships without capability gating — if the model
    // rejects it, the API error names the field.
    if let fixed { return wireEffort(fixed) }
    let requested: ClaudeModel.Effort? =
      switch options.reasoningLevel {
      case .none: nil
      case .light: .low
      case .moderate: .medium
      case .deep: .high
      // Escape hatch: a custom level naming a Claude effort ("xhigh", "max")
      // maps directly; anything else is dropped below.
      case .custom(let level): ClaudeModel.Effort(rawValue: level)
      @unknown default: nil
      }
    // Sending an unsupported level is a hard 400. Drop rather than fail —
    // reasoningLevel is a hint, not a contract.
    guard let requested, model.capabilities.effortLevels.contains(requested) else {
      return nil
    }
    return wireEffort(requested)
  }

  /// Public ``ClaudeModel/Effort`` → wire-level `output_config.effort`.
  private static func wireEffort(_ effort: ClaudeModel.Effort) -> OutputConfig.Effort {
    switch effort {
    case .low: .low
    case .medium: .medium
    case .high: .high
    case .xhigh: .xhigh
    case .max: .max
    }
  }

  /// `.allowed` is the API's default — omitted rather than sent.
  private static func toolChoice(
    for mode: GenerationOptions.ToolCallingMode?
  ) -> ToolChoice? {
    guard let mode else { return nil }
    switch mode.kind {
    case .required: return .any
    case .disallowed: return ToolChoice.none
    case .allowed: return nil
    @unknown default: return nil
    }
  }

  /// Sampling is a hint. Sonnet 5 and Opus 4.7+ reject non-default
  /// `temperature`/`top_p`/`top_k` outright (gated by `samplingParams`), and
  /// whether the 4.6 generation accepts sampling alongside thinking is
  /// undocumented — so sampling flows only when the request carries no
  /// thinking. For sampling control on a thinking-capable model, declare a
  /// custom ``ClaudeModel`` with `adaptiveThinking: false`.
  private static func applySampling(
    _ options: GenerationOptions,
    to req: inout MessagesRequest,
    model: ClaudeModel
  ) {
    guard model.capabilities.samplingParams, req.thinking == nil else { return }
    req.temperature = options.temperature
    switch options.samplingMode?.kind {
    case .greedy:
      req.temperature = 0
    case .randomTopK(let k, _):  // the API has no sampling-seed parameter
      req.topK = k
    case .randomProbabilityThreshold(let threshold, _):
      req.topP = threshold
    case nil:
      break
    @unknown default:
      break
    }
  }

  /// Strict JSON Schema via constrained decoding — the model cannot emit a
  /// token that violates the schema. Compatible with thinking; the response
  /// streams as plain text deltas containing valid JSON.
  private static func applyStructuredOutput(
    _ schema: GenerationSchema,
    includeInPrompt: Bool,
    to req: inout MessagesRequest
  ) {
    let format = OutputConfig.Format(schema: jsonSchema(from: schema))
    req.outputConfig = OutputConfig(format: format, effort: req.outputConfig?.effort)

    if includeInPrompt {
      let hint = "Respond with a single JSON object matching the required schema."
      req.system = (req.system.map { $0 + "\n\n" } ?? "") + hint
    }
  }
}
