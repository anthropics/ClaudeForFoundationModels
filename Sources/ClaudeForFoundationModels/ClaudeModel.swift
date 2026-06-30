// Copyright 2026 Anthropic PBC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// A Claude model and what it accepts. Capabilities drive which request fields
/// the bridge includes — sending a field a model rejects is a hard 400.
///
/// Use a constant for compiled-in models, or the full initializer with the
/// model's capabilities for IDs that aren't compiled in. There is deliberately
/// no ID-only shorthand: it would have to guess the capabilities, and a wrong
/// guess is either a hard 400 (field sent to a model that rejects it) or a
/// silently degraded request (field withheld from a model that wants it).
public struct ClaudeModel: Sendable, Hashable {
  public let id: String
  public let capabilities: Capabilities

  public init(id: String, capabilities: Capabilities) {
    self.id = id
    self.capabilities = capabilities
  }

  public struct Capabilities: Sendable, Hashable {
    /// `temperature` / `top_p` / `top_k`. Removed on Opus 4.7+.
    public var samplingParams: Bool
    /// `output_config.effort` levels the model accepts. Empty = none.
    public var effortLevels: Set<Effort>
    /// `thinking: {"type": "adaptive"}` (extended thinking).
    public var adaptiveThinking: Bool
    /// `output_config.format` (constrained-decoding structured output).
    public var structuredOutput: Bool
    /// Image content blocks.
    public var imageInput: Bool

    public init(
      samplingParams: Bool = false,
      effortLevels: Set<Effort> = [],
      adaptiveThinking: Bool = false,
      structuredOutput: Bool = false,
      imageInput: Bool = false
    ) {
      self.samplingParams = samplingParams
      self.effortLevels = effortLevels
      self.adaptiveThinking = adaptiveThinking
      self.structuredOutput = structuredOutput
      self.imageInput = imageInput
    }
  }

  /// `output_config.effort` level — how much reasoning and output budget the
  /// model spends on a response. Which levels a model accepts varies; see
  /// ``Capabilities/effortLevels``.
  public enum Effort: String, Sendable, Hashable {
    case low, medium, high, xhigh, max
  }

  // Capability matrix per the Messages API docs: sampling params are rejected
  // on Sonnet 5 and Opus 4.7+ (Opus 4.6 still accepts them), `.xhigh` exists
  // only on Opus 4.7+, and `.max` requires the 4.6 generation or newer.
  /// High-performance model for coding and agents.
  public static let sonnet5 = ClaudeModel(
    id: "claude-sonnet-5",
    capabilities: .init(
      effortLevels: [.low, .medium, .high, .max],
      adaptiveThinking: true,
      structuredOutput: true,
      imageInput: true
    )
  )
  public static let opus4_8 = ClaudeModel(
    id: "claude-opus-4-8",
    capabilities: .init(
      effortLevels: [.low, .medium, .high, .xhigh, .max],
      adaptiveThinking: true,
      structuredOutput: true,
      imageInput: true
    )
  )
  public static let opus4_7 = ClaudeModel(
    id: "claude-opus-4-7",
    capabilities: .init(
      effortLevels: [.low, .medium, .high, .xhigh, .max],
      adaptiveThinking: true,
      structuredOutput: true,
      imageInput: true
    )
  )
  public static let opus4_6 = ClaudeModel(
    id: "claude-opus-4-6",
    capabilities: .init(
      samplingParams: true,
      effortLevels: [.low, .medium, .high, .max],
      adaptiveThinking: true,
      structuredOutput: true,
      imageInput: true
    )
  )
  public static let sonnet4_6 = ClaudeModel(
    id: "claude-sonnet-4-6",
    capabilities: .init(
      samplingParams: true,
      effortLevels: [.low, .medium, .high, .max],
      adaptiveThinking: true,
      structuredOutput: true,
      imageInput: true
    )
  )
  // Haiku 4.5 supports manual extended thinking only, which the bridge
  // doesn't send — adaptive thinking is a 4.6-generation feature.
  public static let haiku4_5 = ClaudeModel(
    id: "claude-haiku-4-5",
    capabilities: .init(
      samplingParams: true,
      structuredOutput: true,
      imageInput: true
    )
  )
}
