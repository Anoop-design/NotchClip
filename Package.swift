// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchClip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NotchClipCore", targets: ["NotchClipCore"]),
        .executable(name: "NotchClip", targets: ["NotchClip"])
    ],
    targets: [
        .target(
            name: "NotchClipCore",
            path: "Sources/NotchClipCore"
        ),
        .executableTarget(
            name: "NotchClip",
            dependencies: ["NotchClipCore"],
            path: "Sources/NotchClip"
        ),
        .testTarget(
            name: "NotchClipCoreTests",
            dependencies: ["NotchClipCore", "NotchClip"],
            path: "Tests/NotchClipCoreTests"
        )
    ]
)
