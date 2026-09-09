// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

/// Names of request headers that the API defines.
package enum HeaderName {
  /// The opt-ins that a request needs, as a comma-separated list.
  package static let beta = "anthropic-beta"
  /// The user profile that a request is attributed to.
  package static let userProfileID = "anthropic-user-profile-id"
}

/// User profiles, which attribute requests to someone other than the
/// organization.
package enum UserProfiles {
  /// The `anthropic-beta` value that ``HeaderName/userProfileID`` needs.
  package static let betaHeader = "user-profiles-2026-08-18"
}
