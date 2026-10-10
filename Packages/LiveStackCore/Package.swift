// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveStackCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LiveStackCore", targets: ["LiveStackCore"])
    ],
    targets: [
        .target(name: "LiveStackCore"),
        .testTarget(name: "LiveStackCoreTests", dependencies: ["LiveStackCore"])
    ]
)
