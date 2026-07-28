// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GeoNavKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "GeoNavKit", targets: ["GeoNavKit"]),
    ],
    targets: [
        .target(name: "GeoNavKit"),
        .testTarget(name: "GeoNavKitTests", dependencies: ["GeoNavKit"]),
    ]
)
