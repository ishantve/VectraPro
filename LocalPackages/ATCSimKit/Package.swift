// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ATCSimKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ATCSimKit", targets: ["ATCSimKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ishantve/GeoNavKit.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "ATCSimKit", dependencies: [.product(name: "GeoNavKit", package: "GeoNavKit")]),
        .testTarget(name: "ATCSimKitTests", dependencies: ["ATCSimKit"]),
    ]
)
