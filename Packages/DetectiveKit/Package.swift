// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DetectiveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DetectiveKit", targets: ["DetectiveKit"])
    ],
    targets: [
        .target(name: "DetectiveKit"),
        .testTarget(name: "DetectiveKitTests", dependencies: ["DetectiveKit"])
    ]
)
