// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeechKit",
    platforms: [.iOS(.v17)],   // AVAudioApplication.requestRecordPermission is iOS 17+
    products: [
        .library(name: "SpeechKit", targets: ["SpeechKit"]),
    ],
    dependencies: [
        .package(path: "../MicrosoftCognitiveServicesSpeech"),
    ],
    targets: [
        .target(
            name: "SpeechKit",
            dependencies: [
                .product(name: "MicrosoftCognitiveServicesSpeech",
                         package: "MicrosoftCognitiveServicesSpeech"),
            ]
        ),
    ]
)
