// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DetectiveKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DetectiveKit", targets: ["DetectiveKit"])
    ],
    targets: [
        .target(name: "DetectiveKit", resources: [.process("Resources")]),
        .testTarget(name: "DetectiveKitTests", dependencies: ["DetectiveKit"])
    ]
)
