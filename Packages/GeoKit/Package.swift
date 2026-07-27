// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GeoKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "GeoKit", targets: ["GeoKit"]),
    ],
    targets: [
        .target(name: "GeoKit"),
        .testTarget(name: "GeoKitTests", dependencies: ["GeoKit"]),
    ]
)
