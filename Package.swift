// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AntigravityWidget",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AntigravityWidget", targets: ["AntigravityWidget"]),
        .executable(name: "agy-usage", targets: ["agy-usage"]),
        .library(name: "AGUsageCore", targets: ["AGUsageCore"]),
    ],
    targets: [
        // Pure data layer: discovers Antigravity data dirs, parses transcripts,
        // logs and SQLite summaries, and aggregates usage. No UI dependencies.
        .target(
            name: "AGUsageCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The floating SwiftUI/AppKit widget.
        .executableTarget(
            name: "AntigravityWidget",
            dependencies: ["AGUsageCore"]
        ),
        // Small CLI that prints the same stats to the terminal (handy for debugging).
        .executableTarget(
            name: "agy-usage",
            dependencies: ["AGUsageCore"]
        ),
        .testTarget(
            name: "AGUsageCoreTests",
            dependencies: ["AGUsageCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
