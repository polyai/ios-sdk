// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PolyMessaging",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "PolyMessaging",
            targets: ["PolyMessaging"]
        ),
    ],
    targets: [
        .target(
            name: "PolyMessaging",
            path: "Sources/PolyMessaging"
        ),
        .testTarget(
            name: "PolyMessagingTests",
            dependencies: ["PolyMessaging"],
            path: "Tests/PolyMessagingTests"
        ),
    ]
)
