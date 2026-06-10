// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ClaudeAPI

@Suite struct TelemetryTests {
  @Test func `user agent carries the sdk, swift, and platform components`() {
    let userAgent = Telemetry.userAgent
    #expect(userAgent.hasPrefix("ClaudeForFoundationModels/\(Telemetry.sdkVersion)"))
    #expect(userAgent.contains("Swift/"))
    #expect(
      userAgent.contains("macOS/") || userAgent.contains("iOS/") || userAgent.contains("visionOS/")
        || userAgent.contains("unknown/")
    )
  }

  @Test func `the app component is folded in only when a bundle id exists`() {
    // In the test runner there's usually no `CFBundleIdentifier`, so the
    // comment starts at the Swift token. When a bundle id is present it leads
    // the comment.
    let userAgent = Telemetry.userAgent
    if let app = Telemetry.appComponent {
      #expect(userAgent.contains("(\(app); Swift/"))
    } else {
      #expect(userAgent.contains("(Swift/"))
    }
  }
}
