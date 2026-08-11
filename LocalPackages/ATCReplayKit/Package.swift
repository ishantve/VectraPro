// swift-tools-version: 5.9
import PackageDescription

// VectraPro's ATC-specific replay layer.
//
// The generic record/replay/determinism platform now lives in the standalone ReplayCore package, consumed
// remotely below. This package holds only ATC vocabulary (ATCReplayAdapter) plus thin umbrellas that keep
// the app's existing `import ATCReplayKit` / `import ATCReplayStore` working unchanged — the umbrellas
// `@_exported import` the remote ReplayCore/ReplayPersistence + the ATC adapter.
let package = Package(
    name: "ATCReplayKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ATCReplayKit", targets: ["ATCReplayKit"]),
        .library(name: "ATCReplayStore", targets: ["ATCReplayStore"]),
        .library(name: "ATCReplayAdapter", targets: ["ATCReplayAdapter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ishantve/ReplayCore.git", from: "0.1.0"),
    ],
    targets: [
        // ATC event vocabulary: ATCEvent / ATCPayload / ATCEventCodec, built on ReplayCore's public API.
        .target(name: "ATCReplayAdapter",
                dependencies: [.product(name: "ReplayCore", package: "ReplayCore")]),

        // Umbrella: `@_exported import ReplayCore` + `ATCReplayAdapter`, so the app's `import ATCReplayKit`
        // sees the same surface it did before the extraction.
        .target(name: "ATCReplayKit",
                dependencies: [.product(name: "ReplayCore", package: "ReplayCore"), "ATCReplayAdapter"]),

        // Umbrella re-exporting the remote SQLite catalogue.
        .target(name: "ATCReplayStore",
                dependencies: [.product(name: "ReplayPersistence", package: "ReplayCore")]),

        // ATC adapter conformance + format tests, against ReplayCore's PUBLIC API (see Option A).
        .testTarget(name: "ATCReplayKitTests",
                    dependencies: ["ATCReplayKit", "ATCReplayAdapter", "ATCReplayStore",
                                   .product(name: "ReplayCore", package: "ReplayCore"),
                                   .product(name: "ReplayPersistence", package: "ReplayCore")]),
    ]
)
