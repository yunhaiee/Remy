// swift-tools-version: 5.9
// Packaging-only adapter for the unmodified Google LiteRT-LM v0.18.1 Swift sources.
// See UPSTREAM.json and LICENSE. The native binary and checksum are from Google's release manifest.
import PackageDescription

let package = Package(
    name: "LiteRTLM",
    platforms: [.iOS(.v15)],
    products: [.library(name: "LiteRTLM", targets: ["LiteRTLM"])],
    targets: [
        .binaryTarget(name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.1/CLiteRTLM.xcframework.zip",
            checksum: "5c51905e38c77ccc611dc2f8c2af6cf5144621046f1dde6518aab83f78488937"),
        .target(name: "LiteRTLM", dependencies: ["CLiteRTLM"], path: "Sources")
    ]
)
