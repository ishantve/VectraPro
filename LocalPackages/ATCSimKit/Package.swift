// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ATCSimKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ATCSimKit", targets: ["ATCSimKit"]),
    ],
    dependencies: [
        .package(path: "../GeoNavKit"),
    ],
    targets: [
        .target(name: "ATCSimKit", dependencies: ["GeoNavKit"]),
        .testTarget(name: "ATCSimKitTests", dependencies: ["ATCSimKit"]),
    ]
)
