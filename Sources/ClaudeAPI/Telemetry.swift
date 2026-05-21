// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Builds the `User-Agent`:
/// `{app}/{version} ({sdk}/{version}; Swift/{version}; {os}/{version})`.
///
/// The leading `{app}/{version}` is the embedding app's bundle ID and marketing
/// version, auto-discovered from `Bundle.main` so the developer does nothing.
/// This is the per-app attribution for API-key and proxy auth where there's no
/// `application_slug`. Best-effort and self-reported — analytics, not a trust
/// boundary.
package enum Telemetry {
  package static let sdkVersion = "0.1.0"

  package static var userAgent: String {
    let app = appComponent.map { "\($0) " } ?? ""
    return "\(app)ClaudeAPI/\(sdkVersion) (Swift/\(swiftVersion); \(platform))"
  }

  /// `{bundle.id}/{marketing-version}`, or `nil` outside an app bundle (CLI,
  /// tests) where there's no `CFBundleIdentifier`.
  static var appComponent: String? {
    let bundle = Bundle.main
    guard let id = bundle.bundleIdentifier else { return nil }
    let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    return "\(id)/\(version)"
  }

  static var swiftVersion: String {
    #if swift(>=6.3)
    "6.3"
    #elseif swift(>=6.2)
    "6.2"
    #else
    "6"
    #endif
  }

  static var platform: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    #if os(iOS)
    return "iOS/\(version)"
    #elseif os(macOS)
    return "macOS/\(version)"
    #elseif os(visionOS)
    return "visionOS/\(version)"
    #else
    return "unknown/\(version)"
    #endif
  }
}
