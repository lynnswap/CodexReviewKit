// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "CodexAppServerKit",
            targets: ["CodexAppServerKit"]
        ),
        .library(
            name: "CodexAppServerKitTesting",
            targets: ["CodexAppServerKitTesting"]
        ),
        .library(
            name: "CodexDataKit",
            targets: ["CodexDataKit"]
        ),
        .library(
            name: "CodexReviewKit",
            targets: ["CodexReviewKit"]
        ),
        .library(
            name: "CodexReviewHost",
            targets: ["CodexReviewHost"]
        ),
        .library(
            name: "ReviewUI",
            targets: ["ReviewUI"]
        ),
        .library(
            name: "ReviewUIPreviewSupport",
            targets: ["ReviewUIPreviewSupport"]
        ),
        .library(
            name: "TextTransitions",
            targets: ["TextTransitions"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/lynnswap/swift-sdk.git",
            revision: "fae7761fd5d257b24e1d9c49c6dc121e188e0d9b"
        ),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.1"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", .upToNextMinor(from: "0.12.0")),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "CodexAppServerKit",
            exclude: ["README.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .target(
            name: "CodexAppServerKitTesting",
            dependencies: [
                "CodexAppServerKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .target(
            name: "CodexDataKit",
            dependencies: [
                "CodexAppServerKit",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            exclude: ["README.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
        ),
        .target(
            name: "CodexReviewKit",
            dependencies: [
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewAppServer",
            dependencies: [
                "CodexAppServerKit",
                "CodexDataKit",
                "CodexReviewKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewMCPServer",
            dependencies: [
                "CodexAppServerKit",
                "CodexDataKit",
                "CodexReviewKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewHost",
            dependencies: [
                "CodexAppServerKit",
                "CodexDataKit",
                "CodexReviewKit",
                "CodexReviewAppServer",
                "CodexReviewMCPServer",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewTesting",
            dependencies: [
                "CodexAppServerKit",
                "CodexAppServerKitTesting",
                "CodexReviewKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewUI",
            dependencies: [
                "CodexReviewKit",
                "ReviewChatLogUI",
                "CodexAppServerKit",
                "CodexDataKit",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewChatLogUI",
            dependencies: [
                "TextTransitions",
                "CodexAppServerKit",
                "CodexDataKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewUIPreviewSupport",
            dependencies: [
                "CodexAppServerKit",
                "CodexDataKit",
                "CodexAppServerKitTesting",
                "CodexReviewKit",
                "ReviewUI",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "TextTransitions",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexAppServerKitTests",
            dependencies: [
                "CodexAppServerKit",
                "CodexAppServerKitTesting",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "CodexDataKitTests",
            dependencies: [
                "CodexDataKit",
                "CodexAppServerKitTesting",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
        ),
        .testTarget(
            name: "CodexReviewKitTests",
            dependencies: ["CodexReviewKit", "CodexReviewTesting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewAppServerTests",
            dependencies: [
                "CodexAppServerKit",
                "CodexAppServerKitTesting",
                "CodexDataKit",
                "CodexReviewAppServer",
                "CodexReviewKit",
                "CodexReviewTesting",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewMCPServerTests",
            dependencies: [
                "CodexAppServerKit",
                "CodexDataKit",
                "CodexReviewMCPServer",
                "CodexReviewTesting",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewHostTests",
            dependencies: [
                "CodexAppServerKit",
                "CodexAppServerKitTesting",
                "CodexReviewAppServer",
                "CodexReviewHost",
                "CodexReviewTesting",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewUITests",
            dependencies: [
                "CodexAppServerKit",
                "CodexDataKit",
                "CodexAppServerKitTesting",
                "CodexReviewKit",
                "CodexReviewTesting",
                "ReviewChatLogUI",
                "ReviewUI",
                "ReviewUIPreviewSupport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "TextTransitionsTests",
            dependencies: [
                "TextTransitions",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
