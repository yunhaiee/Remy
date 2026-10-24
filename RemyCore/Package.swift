// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemyCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "RemyCore", targets: ["RemyCore"])],
    targets: [
        .target(name: "RemyCore"),
        .testTarget(name: "RemyCoreTests", dependencies: ["RemyCore"])
    ]
)
