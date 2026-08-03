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
        .library(name: "ATCReplayKit", targets: ["ATCReplayKit"]),
        .library(name: "ATCReplayStore", targets: ["ATCReplayStore"]),
    ],
    targets: [
        // The portable core: sessions, events, manifests, managers. Foundation only.
        .target(name: "ATCReplayKit"),

        // The catalogue's SQLite implementation, split out so the core stays free of a platform
        // library. The catalogue is the one part that genuinely wants a database — it answers queries
        // and wants transactions — and this is where that dependency is confined.
        .target(name: "ATCReplayStore",
                dependencies: ["ATCReplayKit"],
                linkerSettings: [.linkedLibrary("sqlite3")]),

        .testTarget(name: "ATCReplayKitTests",
                    dependencies: ["ATCReplayKit", "ATCReplayStore"]),
    ]
)
