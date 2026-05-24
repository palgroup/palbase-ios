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

        // The `palbackend` product: a single curated façade for apps with
        // a managed backend. `import PalBackend` surfaces only the backend
        // RPC + auth; Core/AppAttest/transport stay internal. Deliberately
        // does NOT expose PalbaseDB — a backend app goes through its
        // backend, not direct-to-DB. See
        // docs/superpowers/specs/2026-05-24-palbackend-ios-sdk-design.md.
        .library(name: "PalBackend", targets: ["PalBackend"]),
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
        .target(name: "PalbaseBackend", dependencies: ["PalbaseCore"], exclude: ["README.md"]),

        // App Attest provider — internal target, conforms to Core's
        // `AppAttesting`. Linked by the PalBackend façade; never a product
        // on its own (the developer never imports it directly).
        .target(name: "PalbaseAppAttest", dependencies: ["PalbaseCore"]),

        // PalBackend façade target — re-exports the curated surface.
        .target(
            name: "PalBackend",
            dependencies: ["PalbaseBackend", "PalbaseAuth", "PalbaseAppAttest"],
            exclude: ["README.md"]
        ),

        .testTarget(name: "PalbaseCoreTests", dependencies: ["PalbaseCore"]),
        .testTarget(name: "PalbaseDBTests", dependencies: ["PalbaseDB"]),
        .testTarget(name: "PalbaseDocsTests", dependencies: ["PalbaseDocs"]),
        .testTarget(name: "PalbaseStorageTests", dependencies: ["PalbaseStorage"]),
        .testTarget(name: "PalbaseRealtimeTests", dependencies: ["PalbaseRealtime"]),
        .testTarget(name: "PalbaseAnalyticsTests", dependencies: ["PalbaseAnalytics"]),
        .testTarget(name: "PalbaseFlagsTests", dependencies: ["PalbaseFlags"]),
        .testTarget(name: "PalbaseBackendTests", dependencies: ["PalbaseBackend"]),
        .testTarget(name: "PalbaseAppAttestTests", dependencies: ["PalbaseAppAttest"]),
        .testTarget(name: "PalBackendTests", dependencies: ["PalBackend"]),

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
