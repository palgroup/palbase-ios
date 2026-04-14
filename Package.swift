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
        // Umbrella — re-exports everything
        .library(name: "Palbase", targets: ["Palbase"]),

        // Granular per-module (like Firebase)
        .library(name: "PalbaseCore", targets: ["PalbaseCore"]),
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
    ],
    targets: [
        .target(name: "PalbaseCore"),

        .target(name: "PalbaseAuth", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseDB", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseDocs", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseStorage", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseRealtime", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseFunctions", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseFlags", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseNotifications", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseAnalytics", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseLinks", dependencies: ["PalbaseCore"]),
        .target(name: "PalbaseCms", dependencies: ["PalbaseCore"]),

        // Umbrella: depends on everything
        .target(
            name: "Palbase",
            dependencies: [
                "PalbaseCore",
                "PalbaseAuth",
                "PalbaseDB",
                "PalbaseDocs",
                "PalbaseStorage",
                "PalbaseRealtime",
                "PalbaseFunctions",
                "PalbaseFlags",
                "PalbaseNotifications",
                "PalbaseAnalytics",
                "PalbaseLinks",
                "PalbaseCms",
            ]
        ),

        // Tests
        .testTarget(name: "PalbaseCoreTests", dependencies: ["PalbaseCore"]),
    ],
    swiftLanguageModes: [.v6]
)
