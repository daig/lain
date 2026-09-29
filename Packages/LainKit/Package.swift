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
                .target(name: "LainUSBMux", condition: .when(platforms: [.macOS])),
                .target(name: "CGVirtualDisplayPrivate", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "LainClientCore",
            dependencies: ["LainProtocol", "LainTelemetry", "LainInput", "LainTransport", "LainMedia"]
        ),
        // Fakes for integration tests (fake usbmuxd); never linked into the apps.
        .target(name: "LainTestSupport", dependencies: ["LainUSBMux"]),
        .testTarget(name: "LainProtocolTests", dependencies: ["LainProtocol"]),
        .testTarget(name: "LainTelemetryTests", dependencies: ["LainTelemetry"]),
        .testTarget(name: "LainInputTests", dependencies: ["LainInput"]),
        .testTarget(name: "LainMediaTests", dependencies: ["LainMedia", "LainTestSupport"]),
        .testTarget(name: "LainHostCoreTests", dependencies: ["LainHostCore", "LainTransport", "LainUSBMux", "LainTestSupport"]),
        .testTarget(name: "LainClientCoreTests",
                    dependencies: ["LainClientCore", "LainInput", "LainProtocol", "LainTransport", "LainTelemetry"]),
        .testTarget(name: "LainUSBMuxTests", dependencies: ["LainUSBMux", "LainTestSupport"]),
        .testTarget(name: "LainTransportTests", dependencies: ["LainTransport", "LainTestSupport", "LainTelemetry"]),
        // Host ↔ client end to end on macOS (the client core is platform-neutral where it matters).
        .testTarget(name: "LainLoopbackTests",
                    dependencies: ["LainHostCore", "LainClientCore", "LainMedia", "LainTransport", "LainTelemetry", "LainTestSupport"]),
    ]
)
