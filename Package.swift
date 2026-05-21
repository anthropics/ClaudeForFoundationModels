// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ClaudeForFoundationModels",
  // Every OS where Foundation Models supports server-side language models.
  // Spelled as strings because the .v27 constants require tools-version 6.4.
  platforms: [
    .iOS("27.0"), .macOS("27.0"), .visionOS("27.0"), .watchOS("27.0"),
  ],
  products: [
    .library(name: "ClaudeForFoundationModels", targets: ["ClaudeForFoundationModels"])
  ],
  targets: [
    // Internal Messages API client. No FoundationModels dependency.
    .target(name: "ClaudeAPI"),

    // FoundationModels ↔ Messages API bridge.
    .target(
      name: "ClaudeForFoundationModels",
      dependencies: ["ClaudeAPI"]
    ),

    // Runnable usage example (`swift run ClaudeExample`). Deliberately not a
    // product — it exists to document the SDK, not to be depended on.
    .executableTarget(
      name: "ClaudeExample",
      dependencies: ["ClaudeForFoundationModels"],
      path: "Examples/ClaudeExample"
    ),

    .testTarget(
      name: "ClaudeAPITests",
      dependencies: ["ClaudeAPI"]
    ),
    .testTarget(
      name: "ClaudeForFoundationModelsTests",
      dependencies: ["ClaudeForFoundationModels"]
    ),
  ]
)
