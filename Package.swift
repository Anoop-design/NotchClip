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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "NotchClipCore",
            path: "Sources/NotchClipCore"
        ),
        .executableTarget(
            name: "NotchClip",
            dependencies: [
                "NotchClipCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/NotchClip"
        ),
        .testTarget(
            name: "NotchClipCoreTests",
            dependencies: ["NotchClipCore", "NotchClip"],
            path: "Tests/NotchClipCoreTests"
        )
    ]
)
