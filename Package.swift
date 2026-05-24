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
        // App Attest: opt-in device/app-integrity enforcement. Import and
        // call `Palbase.enableAppAttest()` once after configure; every
        // request then carries an assertion.
        .library(name: "PalbaseAppAttest", targets: ["PalbaseAppAttest"]),
        // NOTE: the managed-backend SDK now lives in its own repo,
        // `palbackend-ios` (palgroup/palbackend-ios). palbase-ios is the
        // small-project surface only (auth + db + storage + realtime + …);
        // it intentionally ships no backend module.
    ],
    targets: [
        .target(name: "PalbaseCore", exclude: ["README.md"]),
        .target(name: "PalbaseAuth", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseDB", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseDocs", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseStorage", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseRealtime", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseFunctions", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseFlags", dependencies: ["PalbaseCore", "PalbaseRealtime"], exclude: ["README.md"]),
        .target(name: "PalbaseNotifications", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseAnalytics", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseLinks", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseCms", dependencies: ["PalbaseCore"], exclude: ["README.md"]),
        .target(name: "PalbaseAppAttest", dependencies: ["PalbaseCore"]),

        .testTarget(name: "PalbaseCoreTests", dependencies: ["PalbaseCore"]),
        .testTarget(name: "PalbaseDBTests", dependencies: ["PalbaseDB"]),
        .testTarget(name: "PalbaseDocsTests", dependencies: ["PalbaseDocs"]),
        .testTarget(name: "PalbaseStorageTests", dependencies: ["PalbaseStorage"]),
        .testTarget(name: "PalbaseRealtimeTests", dependencies: ["PalbaseRealtime"]),
        .testTarget(name: "PalbaseAnalyticsTests", dependencies: ["PalbaseAnalytics"]),
        .testTarget(name: "PalbaseFlagsTests", dependencies: ["PalbaseFlags"]),
        .testTarget(name: "PalbaseAppAttestTests", dependencies: ["PalbaseAppAttest"]),

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
