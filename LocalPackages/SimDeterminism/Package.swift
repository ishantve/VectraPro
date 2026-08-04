// swift-tools-version: 5.9
import PackageDescription

// Deterministic simulation primitives, and nothing else.
//
// The admission test for this package is: *would another deterministic simulation want this without adopting
// replay?* Only two types passed it. Everything that failed stayed in ATCSimKit, including two that an earlier
// draft of the extraction plan had listed for the move:
//
//  · `RandomStreams` — its streams are named `spawner`, `promotion`, `traffic`, `weather`. That is ATC
//    vocabulary. The *mechanism* of deriving independent streams from one seed is generic; the roster is not,
//    and a package whose public surface names an aircraft spawner is not conceptually pure.
//  · `StateHash` — `init(clock:radar:hangar:)` takes `[Aircraft]` and mixes aircraft fields. It is a fingerprint
//    *of an ATC world*. The FNV-1a machinery inside it is generic, but extracting that today would add a public
//    type nothing uses, which is the speculative abstraction this migration is explicitly avoiding.
//
// So this package has two types. That is the point — it is small because the test was applied honestly rather
// than to reach a tidier package diagram.
let package = Package(
    name: "SimDeterminism",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "SimDeterminism", targets: ["SimDeterminism"]),
    ],
    targets: [
        .target(name: "SimDeterminism"),
        .testTarget(name: "SimDeterminismTests", dependencies: ["SimDeterminism"]),
    ]
)
