// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Loosely-typed JSON for tool inputs/outputs and schemas, where the shape
/// is determined at runtime.
package enum JSONValue: Sendable, Hashable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  package init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
      return
    }
    if let v = try? c.decode(Bool.self) {
      self = .bool(v)
      return
    }
    if let v = try? c.decode(Double.self) {
      self = .number(v)
      return
    }
    if let v = try? c.decode(String.self) {
      self = .string(v)
      return
    }
    if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
      return
    }
    if let v = try? c.decode([String: JSONValue].self) {
      self = .object(v)
      return
    }
    throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
  }

  package func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  package init(nilLiteral: ()) { self = .null }
  package init(booleanLiteral value: Bool) { self = .bool(value) }
  package init(integerLiteral value: Int) { self = .number(Double(value)) }
  package init(floatLiteral value: Double) { self = .number(value) }
  package init(stringLiteral value: String) { self = .string(value) }
  package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  package init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(.init(uniqueKeysWithValues: elements))
  }
}
