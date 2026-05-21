// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct Message: Sendable, Hashable, Codable {
  package enum Role: String, Sendable, Codable { case user, assistant }

  package var role: Role
  package var content: [ContentBlock]

  package init(role: Role, content: [ContentBlock]) {
    self.role = role
    self.content = content
  }

  package static func user(_ text: String) -> Message {
    .init(role: .user, content: [.text(text)])
  }

  package static func assistant(_ text: String) -> Message {
    .init(role: .assistant, content: [.text(text)])
  }
}
