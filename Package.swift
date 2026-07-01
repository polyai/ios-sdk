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
        // Voice calling (WebRTC). Separate product so chat-only apps never pull
        // the WebRTC binary — mirrors Android's separate ai.poly:voice artifact.
        .library(
            name: "PolyVoice",
            targets: ["PolyVoice"]
        ),
    ],
    dependencies: [
        // The maintained WebRTC xcframework (same lineage as Android's libwebrtc).
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "149.0.0"),
    ],
    targets: [
        .target(
            name: "PolyMessaging",
            path: "Sources/PolyMessaging"
        ),
        .target(
            name: "PolyVoice",
            dependencies: [
                "PolyMessaging",
                // WebRTC is iOS-only here: its macOS slice doesn't build under `swift build`,
                // and keeping it off macOS lets the messaging test suite keep running there.
                .product(name: "WebRTC", package: "WebRTC", condition: .when(platforms: [.iOS])),
            ],
            path: "Sources/PolyVoice"
        ),
        .testTarget(
            name: "PolyMessagingTests",
            dependencies: ["PolyMessaging"],
            path: "Tests/PolyMessagingTests"
        ),
    ]
)
