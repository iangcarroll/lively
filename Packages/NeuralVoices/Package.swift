// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeuralVoices",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "NeuralVoices", targets: ["NeuralVoices"])],
    targets: [
        .target(name: "NeuralVoices", resources: [.process("Resources")]),
        .testTarget(name: "NeuralVoicesTests", dependencies: ["NeuralVoices"])
    ],
    swiftLanguageModes: [.v6]
)
