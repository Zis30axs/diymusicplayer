// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SigmaMusicKit",
    platforms: [
        .macOS("15.0"),
        .watchOS("26.0")
    ],
    products: [
        .library(name: "SigmaMusicKit", targets: ["SigmaMusicKit"])
    ],
    targets: [
        .target(name: "SigmaMusicKit"),
        .testTarget(name: "SigmaMusicKitTests", dependencies: ["SigmaMusicKit"])
    ]
)
