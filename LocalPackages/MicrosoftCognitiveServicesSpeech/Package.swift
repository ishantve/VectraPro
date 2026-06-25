// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MicrosoftCognitiveServicesSpeech",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(
            name: "MicrosoftCognitiveServicesSpeech",
            targets: ["MicrosoftCognitiveServicesSpeech"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "MicrosoftCognitiveServicesSpeech",
            path: "MicrosoftCognitiveServicesSpeech.xcframework"
        ),
    ]
)
