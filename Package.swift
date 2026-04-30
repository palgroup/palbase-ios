// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Palbase",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        // PalbaseCore is intentionally NOT a product — it's an internal target.
        // Users add only the modules they need (PalbaseAuth, PalbaseDB, etc.) and
        // each module re-exports Core's symbols via @_exported import.
        .library(name: "PalbaseAuth", targets: ["PalbaseAuth"]),
        .library(name: "PalbaseDB", targets: ["PalbaseDB"]),
        .library(name: "PalbaseDocs", targets: ["PalbaseDocs"]),
        .library(name: "PalbaseStorage", targets: ["PalbaseStorage"]),
        .library(name: "PalbaseRealtime", targets: ["PalbaseRealtime"]),
        .library(name: "PalbaseFunctions", targets: ["PalbaseFunctions"]),
        .library(name: "PalbaseFlags", targets: ["PalbaseFlags"]),
        .library(name: "PalbaseNotifications", targets: ["PalbaseNotifications"]),
        .library(name: "PalbaseAnalytics", targets: ["PalbaseAnalytics"]),
        .library(name: "PalbaseLinks", targets: ["PalbaseLinks"]),
        .library(name: "PalbaseCms", targets: ["PalbaseCms"]),
        .library(name: "PalbaseBackend", targets: ["PalbaseBackend"]),
    ],
    targets: [
        .target(name: "PalbaseCore"),
        .target(name: "PalbaseAuth", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseDB", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseDocs", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseStorage", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseRealtime", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseFunctions", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseFlags", dependencies: ["PalbaseCore", "PalbaseRealtime"]),
        .target(name: "PalbaseNotifications", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseAnalytics", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseLinks", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseCms", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseBackend", dependencies: ["PalbaseCore"]),

        .testTarget(name: "PalbaseCoreTests", dependencies: ["PalbaseCore"]),
        .testTarget(name: "PalbaseDBTests", dependencies: ["PalbaseDB"]),
        .testTarget(name: "PalbaseDocsTests", dependencies: ["PalbaseDocs"]),
        .testTarget(name: "PalbaseStorageTests", dependencies: ["PalbaseStorage"]),
        .testTarget(name: "PalbaseRealtimeTests", dependencies: ["PalbaseRealtime"]),
        .testTarget(name: "PalbaseAnalyticsTests", dependencies: ["PalbaseAnalytics"]),
        .testTarget(name: "PalbaseFlagsTests", dependencies: ["PalbaseFlags"]),
        .testTarget(name: "PalbaseBackendTests", dependencies: ["PalbaseBackend"]),

        // Live integration probe — Phase 8.
        //
        // Hits the real `app.dev.palbase.studio` control plane (Studio
        // tRPC) plus the per-tenant Kong gateway. Skipped automatically
        // when the `STUDIO_BASE` environment variable is not set, so
        // `swift test` stays green in offline / CI runs.
        //
        // Run:
        //   STUDIO_BASE=https://app.dev.palbase.studio \
        //     swift test --filter PalbaseLive
        .testTarget(
            name: "PalbaseLiveTests",
            dependencies: [
                "PalbaseAuth",
                "PalbaseDB",
                "PalbaseDocs",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
