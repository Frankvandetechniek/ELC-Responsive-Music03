// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [.library(name: "ELCCore", targets: ["ELCCore"])]
var targets: [Target] = [
    // Platform independent core: sACN, fixtures, show engine, audio analysis, vibe model.
    .target(name: "ELCCore", path: "Sources/ELCCore"),
    .testTarget(name: "ELCCoreTests", dependencies: ["ELCCore"], path: "Tests/ELCCoreTests"),
]

#if os(macOS)
// macOS SwiftUI application (AVFoundation / CoreAudio / SoundAnalysis).
products.append(.executable(name: "ELCResponsive", targets: ["ELCResponsive"]))
targets.append(.executableTarget(name: "ELCResponsive", dependencies: ["ELCCore"], path: "Sources/ELCResponsive"))
#endif

let package = Package(
    name: "ELCResponsive",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
