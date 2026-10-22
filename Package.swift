// swift-tools-version: 5.10
import PackageDescription

// Small, dependency-free regression suite. The application is built by Xcode.
let package = Package(
    name: "SodutoReliability",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SodutoReliability", targets: ["SodutoReliability"])],
    targets: [
        .target(name: "SodutoReliability", path: "Soduto/Core/Diagnostics",
                exclude: ["Diagnostics.swift"],
                sources: ["DiagnosticEvent.swift", "DiagnosticLogStore.swift", "ClipboardSyncState.swift", "RecoveryPolicy.swift"]),
        .testTarget(name: "SodutoReliabilityTests", dependencies: ["SodutoReliability"], path: "Tests/Reliability")
    ]
)
