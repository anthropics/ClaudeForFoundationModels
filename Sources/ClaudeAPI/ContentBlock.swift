// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A single block within a message's `content` array.
package enum ContentBlock: Sendable, Hashable, Codable {
  case text(String)
  case image(ImageSource)
  case toolUse(id: String, name: String, input: JSONValue)
  /// `content` is a block array — tool results may carry text and images.
  case toolResult(toolUseID: String, content: [ContentBlock], isError: Bool = false)
  case thinking(String, signature: String? = nil)
  /// A block held as the JSON object the API sent or is to receive. Decoding
  /// yields this for any type without a typed case (`redacted_thinking` and
  /// the server-side tool blocks among them), so a new content type neither
  /// breaks existing clients nor loses its payload; encoding writes the
  /// object as is.
  case raw(JSONValue)

  private enum CodingKeys: String, CodingKey {
    case type, text, source, id, name, input, thinking, signature
    case toolUseID = "tool_use_id"
    case content
    case isError = "is_error"
  }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "text":
      self = .text(try c.decode(String.self, forKey: .text))
    case "image":
      self = .image(try c.decode(ImageSource.self, forKey: .source))
    case "tool_use":
      self = .toolUse(
        id: try c.decode(String.self, forKey: .id),
        name: try c.decode(String.self, forKey: .name),
        input: try c.decode(JSONValue.self, forKey: .input)
      )
    case "tool_result":
      // The wire shape is a string or a block array; normalize to blocks.
      let blocks: [ContentBlock]
      if let text = try? c.decode(String.self, forKey: .content) {
        blocks = [.text(text)]
      } else {
        blocks = try c.decodeIfPresent([ContentBlock].self, forKey: .content) ?? []
      }
      self = .toolResult(
        toolUseID: try c.decode(String.self, forKey: .toolUseID),
        content: blocks,
        isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
      )
    case "thinking":
      self = .thinking(
        try c.decode(String.self, forKey: .thinking),
        signature: try c.decodeIfPresent(String.self, forKey: .signature)
      )
    default:
      self = .raw(try JSONValue(from: decoder))
    }
  }

  package func encode(to encoder: Encoder) throws {
    if case .raw(let object) = self {
      try object.encode(to: encoder)
      return
    }
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let t):
      try c.encode("text", forKey: .type)
      try c.encode(t, forKey: .text)
    case .image(let s):
      try c.encode("image", forKey: .type)
      try c.encode(s, forKey: .source)
    case .toolUse(let id, let name, let input):
      try c.encode("tool_use", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(name, forKey: .name)
      try c.encode(input, forKey: .input)
    case .toolResult(let toolUseID, let content, let isError):
      try c.encode("tool_result", forKey: .type)
      try c.encode(toolUseID, forKey: .toolUseID)
      // A lone text block keeps the compact string form on the wire.
      if case .text(let text)? = content.first, content.count == 1 {
        try c.encode(text, forKey: .content)
      } else {
        try c.encode(content, forKey: .content)
      }
      if isError { try c.encode(true, forKey: .isError) }
    case .thinking(let t, let signature):
      try c.encode("thinking", forKey: .type)
      try c.encode(t, forKey: .thinking)
      try c.encodeIfPresent(signature, forKey: .signature)
    case .raw:
      break  // written above, without the keyed container
    }
  }
}

/// Image payload for an `image` content block. `data` is raw bytes in memory;
/// it crosses the wire base64-encoded.
package struct ImageSource: Sendable, Hashable, Codable {
  package var mediaType: String
  package var data: Data

  package init(mediaType: String, data: Data) {
    self.mediaType = mediaType
    self.data = data
  }

  private enum CodingKeys: String, CodingKey {
    case type, data
    case mediaType = "media_type"
  }

  package init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mediaType = try c.decode(String.self, forKey: .mediaType)
    let b64 = try c.decode(String.self, forKey: .data)
    guard let bytes = Data(base64Encoded: b64) else {
      throw DecodingError.dataCorruptedError(
        forKey: .data,
        in: c,
        debugDescription: "Invalid base64"
      )
    }
    data = bytes
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode("base64", forKey: .type)
    try c.encode(mediaType, forKey: .mediaType)
    try c.encode(data.base64EncodedString(), forKey: .data)
  }
}
