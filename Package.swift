// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ELCResponsive",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ELCResponsive", targets: ["ELCResponsive"]),
        .library(name: "ELCCore", targets: ["ELCCore"]),
    ],
    targets: [
        // Platform independent core: sACN, fixtures, show engine, audio analysis.
        .target(name: "ELCCore", path: "Sources/ELCCore"),
        // macOS SwiftUI application (AVFoundation / CoreAudio).
        .executableTarget(
            name: "ELCResponsive",
            dependencies: ["ELCCore"],
            path: "Sources/ELCResponsive"
        ),
        .testTarget(name: "ELCCoreTests", dependencies: ["ELCCore"], path: "Tests/ELCCoreTests"),
    ]
)
