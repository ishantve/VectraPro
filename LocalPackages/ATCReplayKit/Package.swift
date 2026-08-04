// swift-tools-version: 5.9
import PackageDescription

// Foundation only, deliberately.
//
// An event records a phraseology *code* and its slot values — not an `AircraftCommand` — so this
// package never needs the simulation engine, and therefore never needs CoreLocation. That keeps it
// portable to a C interface and to React Native and Unity, the same property ATCTrafficKit protects.
//
// It also makes a replay honest: mapping a code to aircraft behaviour is the simulator's job, and a
// fix to that mapping should reach old recordings rather than being frozen into them.
let package = Package(
    name: "ATCReplayKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        // The platform, under its own names.
        .library(name: "ReplayCore", targets: ["ReplayCore"]),
        .library(name: "ReplayPersistence", targets: ["ReplayPersistence"]),

        // The old names, re-exporting the new ones so the application's imports do not move during the
        // migration. Scaffolding — see the umbrella sources.
        .library(name: "ATCReplayKit", targets: ["ATCReplayKit"]),
        .library(name: "ATCReplayStore", targets: ["ATCReplayStore"]),
    ],
    targets: [
        // Replay infrastructure: sessions, lifecycle, events, manifests, recorder, branching, managers.
        // Foundation only. Still holds `EventStore`, because moving it needs a protocol in the core first
        // and that is Phase R4 — a packaging phase must not invert a dependency.
        .target(name: "ReplayCore"),

        // The catalogue's SQLite implementation, split out so the core stays free of a platform library.
        // The catalogue is the one part that genuinely wants a database — it answers queries and wants
        // transactions — and this is where that dependency is confined.
        .target(name: "ReplayPersistence",
                dependencies: ["ReplayCore"],
                linkerSettings: [.linkedLibrary("sqlite3")]),

        .target(name: "ATCReplayKit", dependencies: ["ReplayCore"]),
        .target(name: "ATCReplayStore", dependencies: ["ReplayPersistence"]),

        .testTarget(name: "ATCReplayKitTests",
                    dependencies: ["ReplayCore", "ReplayPersistence"]),
    ]
)
