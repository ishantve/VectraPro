// swift-tools-version: 5.9
import PackageDescription

// Deliberately dependency-free: Foundation only.
//
// ATCSimKit cannot be ported to React Native or Unity — its core types carry
// CLLocationCoordinate2D, which is Apple-only. Traffic scheduling has no such
// need: it is counts, intervals and quotas. Keeping it in its own package with no
// platform dependencies is what makes an FFI (and therefore a Unity or React
// Native port) possible at all, the same way ATCParserKit manages it.
let package = Package(
    name: "ATCTrafficKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ATCTrafficKit", targets: ["ATCTrafficKit"]),
        .library(name: "ATCTrafficFFI", targets: ["ATCTrafficFFI"]),
    ],
    targets: [
        .target(name: "ATCTrafficKit"),
        .target(name: "ATCTrafficFFI", dependencies: ["ATCTrafficKit"]),
        .testTarget(name: "ATCTrafficKitTests", dependencies: ["ATCTrafficKit"]),
    ]
)
