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

    // Replayed thinking blocks are only required during tool use with
    // thinking active, and prior-turn thinking may always be omitted — so
    // reasoning entries replay only on requests that send `thinking`.
    let toolChoice = toolChoice(for: request.generationOptions.toolCallingMode)
    // Forced tool use is a contract — the API rejects thinking alongside
    // it, so thinking yields for that request.
    let thinkingConfig = toolChoice == .any ? nil : thinking(for: model)

    // The framework records one model turn as several consecutive entries
    // (reasoning, response, tool calls); the API wants each turn back as one
    // assistant message.
    var pieces: [Piece] = []
    var turn: [Transcript.Entry] = []
    func closeTurn() {
      if !turn.isEmpty { pieces.append(.turn(turn)) }
      turn = []
    }
    for entry in request.transcript {
      switch entry {
      case .response, .reasoning, .toolCalls:
        turn.append(entry)

      case .instructions(let i):
        closeTurn()
        system = (system.map { $0 + "\n\n" } ?? "") + text(of: i.segments)

      case .prompt(let p):
        closeTurn()
        pieces.append(.user(.init(role: .user, content: try contentBlocks(from: p.segments))))

      case .toolOutput(let out):
        closeTurn()
        // Block content, not flattened text — tool results may carry images.
        let blocks = try contentBlocks(from: out.segments)
        pieces.append(
          .toolResult(
            id: out.id,
            .init(
              role: .user,
              content: [
                .toolResult(toolUseID: out.id, content: blocks.isEmpty ? [.text("")] : blocks)
              ]
            )
          )
        )

      @unknown default:
        break
      }
    }
    closeTurn()

    let pairing = ToolPairing(pieces)
    var messages: [Message] = []
    for piece in pieces {
      switch piece {
      case .user(let message):
        messages.append(message)
      case .toolResult(let id, let message):
        if pairing.accepts(resultOfClientCall: id) { messages.append(message) }
      case .turn(let entries):
        let content = try assistantContent(
          of: entries,
          replayThinking: thinkingConfig != nil,
          pairing: pairing
        )
        if !content.isEmpty { messages.append(.init(role: .assistant, content: content)) }
      }
    }
    // Roles must alternate: parallel tool calls yield one tool-output entry
    // each, and a turn or tool result that replays as nothing leaves its
    // neighbors adjacent.
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

  // MARK: - Assistant turns

  /// The transcript regrouped the way the API sees it: the user's messages,
  /// and one model turn — a stretch of consecutive model entries — per
  /// assistant message.
  private enum Piece {
    case user(Message)
    case toolResult(id: String, Message)
    case turn([Transcript.Entry])
  }

  /// One assistant message from the entries of a turn: their recorded blocks
  /// in the order the API sent them, with any entry that has no record (a
  /// transcript the app assembled, an entry cut off before its first block
  /// completed) rebuilt from what the framework holds.
  ///
  /// Recorded blocks sort by the position they carry; entries recorded in a
  /// different API turn (the transcript left two turns side by side) come
  /// after everything before them; rebuilt blocks follow whatever preceded
  /// them; text cut off mid-block was the last thing its turn produced.
  private static func assistantContent(
    of entries: [Transcript.Entry],
    replayThinking: Bool,
    pairing: ToolPairing
  ) throws -> [ContentBlock] {
    typealias Ordered = (order: (group: Int, rank: Double), block: ContentBlock)
    var ordered: [Ordered] = []
    var group = 0
    var turn: String?
    var latest = -1.0

    func add(_ record: TurnRecord, orRebuild rebuild: () throws -> [ContentBlock]) rethrows {
      guard !record.isEmpty else {
        ordered += try rebuild().map { ((group, latest + 0.5), $0) }
        return
      }
      if let turn, turn != record.turn { (group, latest) = (group + 1, -1) }
      turn = record.turn
      for block in record.blocks {
        if let content = replayable(block, replayThinking: replayThinking, pairing: pairing) {
          ordered.append(((group, Double(block.position)), content))
        }
        latest = max(latest, Double(block.position))
      }
    }

    for entry in entries {
      switch entry {
      case .response(let response):
        let record = TurnRecord(metadata: response.metadata)
        try add(record) { try contentBlocks(from: response.segments) }
        if !record.isEmpty {
          ordered += unfinishedText(of: response, beyond: record).map { ((group, .infinity), $0) }
        }
      case .reasoning(let reasoning):
        add(TurnRecord(metadata: reasoning.metadata)) {
          // Only a signed thought is worth anything to the API, and only on
          // a request that thinks.
          guard replayThinking, let signature = reasoning.signature, !signature.isEmpty else {
            return []
          }
          let thought = text(of: reasoning.segments, separator: "")
          return [.thinking(thought, signature: signature.base64EncodedString())]
        }
      case .toolCalls(let calls):
        for call in calls {
          add(TurnRecord(metadata: call.metadata)) {
            guard pairing.accepts(clientCall: call.id) else { return [] }
            return [.toolUse(id: call.id, name: call.toolName, input: toolInput(call.arguments))]
          }
        }
      default:
        break
      }
    }
    // `sorted` is stable, so blocks sharing an order keep entry order.
    let content = ordered.sorted { $0.order < $1.order }.map(\.block)
    // A turn pruned down to its thoughts alone has nothing the API needs;
    // earlier turns' thinking may always be omitted.
    let hasSubstance = content.contains { block in
      switch block {
      case .thinking: false
      case .raw(let json):
        switch TurnRecord.Kind(json) {
        case .thinking, .redactedThinking: false
        default: true
        }
      default: true
      }
    }
    return hasSubstance ? content : []
  }

  private static func replayable(
    _ block: TurnRecord.Block,
    replayThinking: Bool,
    pairing: ToolPairing
  ) -> ContentBlock? {
    let accepted =
      switch block.kind {
      case .thinking, .redactedThinking: replayThinking
      case .toolUse(let id, _): pairing.accepts(clientCall: id)
      case .serverToolUse(let id, _, _): pairing.accepts(serverCall: id)
      case .serverToolResult(_, let toolUseID, _): pairing.accepts(resultOf: toolUseID)
      case .text, .other: true
      }
    return accepted ? .raw(block.json) : nil
  }

  /// The answer text that streamed after the response's last completed text
  /// block — there is some only when generation was stopped mid-answer. Each
  /// text block streams into a segment of its own, so it is whatever the
  /// prose segments (those not holding a server tool call's place) hold past
  /// the recorded ones.
  private static func unfinishedText(
    of response: Transcript.Response,
    beyond record: TurnRecord
  ) -> [ContentBlock] {
    var recordedCount = 0
    var placeholderIDs: Set<String> = []
    for block in record.blocks {
      switch block.kind {
      case .text: recordedCount += 1
      case .serverToolUse(let id, _, _): placeholderIDs.insert(id)
      default: break
      }
    }
    let pending = response.segments
      .compactMap { segment -> String? in
        guard case .text(let text) = segment, !placeholderIDs.contains(text.id) else { return nil }
        return text.content
      }
      .dropFirst(recordedCount)
      .joined()
    return pending.contains { !$0.isWhitespace } ? [.text(pending)] : []
  }

  /// Which tool blocks the API will accept back. A call — server-side or
  /// client — needs its result somewhere in the transcript; a result needs
  /// its call. The one exception is a server-side call in the turn whose
  /// client tool outputs this request returns: the API runs it on receipt,
  /// so it goes back unanswered. Anything unpaired (a turn stopped before
  /// the result arrived or the tool ran, a call the app trimmed from
  /// history) replays as nothing rather than failing every later request.
  private struct ToolPairing {
    private var serverCalls: Set<String> = []
    private var clientCalls: Set<String> = []
    private var answered: Set<String> = []
    private var pendingServerCalls: Set<String> = []

    init(_ pieces: [Piece]) {
      var trailingResults = 0
      for piece in pieces {
        switch piece {
        case .turn(let entries):
          trailingResults = 0
          for entry in entries {
            if case .toolCalls(let calls) = entry { clientCalls.formUnion(calls.map(\.id)) }
            for block in TurnRecord(of: entry).blocks {
              switch block.kind {
              case .serverToolUse(let id, _, _): serverCalls.insert(id)
              case .serverToolResult(_, let toolUseID, _): answered.insert(toolUseID)
              default: break
              }
            }
          }
        case .toolResult(let id, _):
          trailingResults += 1
          answered.insert(id)
        case .user:
          trailingResults = 0
        }
      }
      guard trailingResults > 0, case .turn(let continued)? = pieces.dropLast(trailingResults).last
      else { return }
      for block in continued.flatMap({ TurnRecord(of: $0).blocks }) {
        if case .serverToolUse(let id, _, _) = block.kind { pendingServerCalls.insert(id) }
      }
    }

    func accepts(clientCall id: String) -> Bool { answered.contains(id) }
    func accepts(serverCall id: String) -> Bool {
      answered.contains(id) || pendingServerCalls.contains(id)
    }
    func accepts(resultOf id: String) -> Bool { serverCalls.contains(id) }
    func accepts(resultOfClientCall id: String) -> Bool { clientCalls.contains(id) }
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
      case .attachment: nil
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
      @unknown default: []
      }
    }
  }

  private static func toolInput(_ arguments: GeneratedContent) -> JSONValue {
    let input = JSONValue(arguments)
    return if case .object = input { input } else { [:] }
  }

  private static func toolDefinition(_ def: Transcript.ToolDefinition) -> ToolDefinition {
    ToolDefinition(
      name: def.name,
      description: def.description,
      inputSchema: jsonSchema(from: def.parameters)
    )
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
