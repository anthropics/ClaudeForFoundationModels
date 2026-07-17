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

/// Identifies the credential the executor uses. `Hashable` so the framework can
/// cache one executor per unique `(model, auth)` pair — two apps get distinct
/// executors. Hash on stable identifiers (the key itself), never on tokens that
/// rotate.
///
public enum AuthMode: Hashable, Sendable {
  /// Developer-supplied API key. Bundled keys are extractable from a shipping
  /// app; for production, use ``proxied(headers:)``.
  case apiKey(String)
  /// Route requests through a developer-run proxy that adds the real credential
  /// server-side. `baseURL` points at the proxy; `headers` are sent on every
  /// request so the proxy can authorize the caller (e.g. a per-app secret or
  /// tenant id). Pass `[:]` when the proxy needs no client-supplied headers.
  ///
  /// These headers are fixed at construction. Per-request values (a rotating
  /// user token) belong in a future provider-based mode, not here.
  case proxied(headers: [String: String])
  /// App Attest. Register the app in the Anthropic console to obtain a
  /// `clientID`; each install then proves it's a genuine, unmodified copy
  /// via the Secure Enclave, and usage is billed to the developer's
  /// workspace. This works without a developer backend, a browser flow,
  /// or any human sign-in.
  ///
  /// Requires a physical device: simulators and hardware without a Secure
  /// Enclave throw ``ClaudeError/attestationUnsupported``.
  ///
  /// A client ID attests against a single `baseURL` per process: the first
  /// session created for it fixes the host, and later use of the same
  /// client ID with a different `baseURL` fails with
  /// ``ClaudeError/attestationFailed`` when that configuration first
  /// serves a request or runs
  /// ``ClaudeLanguageModel/authenticateIfNeeded()``.
  case appAttest(clientID: String)
}
