// swift-tools-version: 6.2
// LainKit: everything testable in lain lives here (ARCHITECTURE.md §8). The apps stay thin.
// Platform-specific sources are wrapped in #if os(...) so every module builds for both platforms.
import PackageDescription

let package = Package(
    name: "LainKit",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "LainHostCore", targets: ["LainHostCore"]),
        .library(name: "LainClientCore", targets: ["LainClientCore"]),
    ],
    targets: [
        .target(name: "LainProtocol"),
        .target(name: "LainTelemetry"),
        .target(name: "LainInput", dependencies: ["LainProtocol"]),
        .target(name: "LainUSBMux"),
        .target(
            name: "LainTransport",
            dependencies: [
                "LainProtocol", "LainTelemetry",
                .target(name: "LainUSBMux", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(name: "LainMedia", dependencies: ["LainProtocol", "LainTelemetry"]),
        // Invariant 5: the only place private API is declared.
        .target(
            name: "CGVirtualDisplayPrivate",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics", .when(platforms: [.macOS]))]
        ),
        .target(
            name: "LainHostCore",
            dependencies: [
                "LainProtocol", "LainTelemetry", "LainInput", "LainTransport", "LainMedia",
                .target(name: "CGVirtualDisplayPrivate", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "LainClientCore",
            dependencies: ["LainProtocol", "LainTelemetry", "LainInput", "LainTransport", "LainMedia"]
        ),
        .testTarget(name: "LainProtocolTests", dependencies: ["LainProtocol"]),
        .testTarget(name: "LainTelemetryTests", dependencies: ["LainTelemetry"]),
        .testTarget(name: "LainInputTests", dependencies: ["LainInput"]),
    ]
)
