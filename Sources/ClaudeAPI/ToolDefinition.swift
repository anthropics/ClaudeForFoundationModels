// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Two wire shapes share the `tools` array — discriminated by the presence of
/// `type`. Custom tools carry `description` + `input_schema`; server-side
/// tools carry a versioned `type` plus tool-specific config keys.
package struct ToolDefinition: Sendable, Hashable, Codable {
  package var name: String
  package var description: String?
  package var inputSchema: JSONValue?
  /// Set for server-side tools, e.g. `"web_search_20260209"`.
  package var serverType: String?
  /// Tool-specific config (e.g. `allowed_domains`, `max_uses`). Encoded
  /// flat at the top level of the tool object.
  package var config: [String: JSONValue]

  /// Custom tool — invoked by the framework via `Tool.call(arguments:)`.
  package init(name: String, description: String, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.serverType = nil
    self.config = [:]
  }

  /// Server-side tool — executed on Anthropic's infrastructure inside a
  /// single round-trip; never invoked client-side.
  package init(serverType: String, name: String, config: [String: JSONValue] = [:]) {
    self.name = name
    self.description = nil
    self.inputSchema = nil
    self.serverType = serverType
    self.config = config
  }

  private enum CodingKeys: String, CodingKey {
    case name, description, type
    case inputSchema = "input_schema"
  }
  private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    serverType = try c.decodeIfPresent(String.self, forKey: .type)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    inputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
    config = [:]
    // Server-side tools carry their config flat at the top level; everything
    // that isn't one of the fixed keys belongs to it.
    if serverType != nil {
      let fixed = Set(["name", "description", "type", "input_schema"])
      let dynamic = try decoder.container(keyedBy: DynamicKey.self)
      for key in dynamic.allKeys where !fixed.contains(key.stringValue) {
        config[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
      }
    }
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    if let serverType {
      try c.encode(serverType, forKey: .type)
      var dynamic = encoder.container(keyedBy: DynamicKey.self)
      for (key, value) in config {
        try dynamic.encode(value, forKey: DynamicKey(stringValue: key))
      }
    } else {
      try c.encodeIfPresent(description, forKey: .description)
      try c.encodeIfPresent(inputSchema, forKey: .inputSchema)
    }
  }
}

package enum ToolChoice: Sendable, Hashable, Codable {
  case auto
  case any
  case none
  case tool(name: String)

  private enum CodingKeys: String, CodingKey { case type, name }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "auto": self = .auto
    case "any": self = .any
    case "none": self = .none
    case "tool": self = .tool(name: try c.decode(String.self, forKey: .name))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: c,
        debugDescription: "Unknown tool_choice '\(other)'"
      )
    }
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .auto: try c.encode("auto", forKey: .type)
    case .any: try c.encode("any", forKey: .type)
    case .none: try c.encode("none", forKey: .type)
    case .tool(let name):
      try c.encode("tool", forKey: .type)
      try c.encode(name, forKey: .name)
    }
  }
}
