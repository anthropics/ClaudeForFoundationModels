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

import ClaudeAPI
import Foundation

/// Server-side tools that execute on Anthropic's infrastructure inside a
/// single round-trip — there is no client-side `call()`. Configured per-model
/// because availability and policy belong to the deployment, not the turn.
///
/// `Hashable` so it folds into the framework's executor cache.
public enum ClaudeServerTool: Hashable, Sendable {
  /// Real-time web search.
  case webSearch(domains: DomainFilter = .unrestricted, maxUses: Int? = nil)
  /// Fetch and read a URL.
  case webFetch(domains: DomainFilter = .unrestricted, maxUses: Int? = nil)
  /// Sandboxed code execution (Python, bash, file ops).
  case codeExecution

  /// Domain policy for the web tools — an allowlist or a blocklist, never
  /// both (the API rejects requests that set both).
  public enum DomainFilter: Hashable, Sendable {
    case unrestricted
    case allowing([String])
    case blocking([String])
  }
}

extension ClaudeServerTool {
  /// `nil` when the tool can't be sent: `.allowing([])` permits no domain at
  /// all, and the wire can't express an empty allowlist — failing closed by
  /// omitting the tool beats silently lifting the restriction.
  var toolDefinition: ToolDefinition? {
    switch self {
    case .webSearch(.allowing(let domains), _) where domains.isEmpty:
      nil
    case .webFetch(.allowing(let domains), _) where domains.isEmpty:
      nil
    case .webSearch(let domains, let maxUses):
      .init(
        serverType: "web_search_20260209",
        name: "web_search",
        config: config(domains: domains, maxUses: maxUses)
      )
    case .webFetch(let domains, let maxUses):
      .init(
        serverType: "web_fetch_20260209",
        name: "web_fetch",
        config: config(domains: domains, maxUses: maxUses)
      )
    case .codeExecution:
      .init(serverType: "code_execution_20260120", name: "code_execution")
    }
  }

  private func config(domains: DomainFilter, maxUses: Int?) -> [String: JSONValue] {
    var c: [String: JSONValue] = [:]
    switch domains {
    case .allowing(let domains) where !domains.isEmpty:
      c["allowed_domains"] = .array(domains.map(JSONValue.string))
    case .blocking(let domains) where !domains.isEmpty:
      c["blocked_domains"] = .array(domains.map(JSONValue.string))
    case .unrestricted, .allowing, .blocking:
      // Blocking nothing is genuinely unrestricted; the empty-allowlist case
      // never reaches here (the tool is omitted above).
      break
    }
    if let maxUses { c["max_uses"] = .number(Double(maxUses)) }
    return c
  }
}
