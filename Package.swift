// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "CodexReviewKit",
            targets: ["CodexReviewKit"]
        ),
        .library(
            name: "CodexReviewHost",
            targets: ["CodexReviewHost"]
        ),
        .library(
            name: "CodexAppServerKit",
            targets: ["CodexAppServerKit"]
        ),
        .library(
            name: "CodexAppServerKitTesting",
            targets: ["CodexAppServerKitTesting"]
        ),
        .library(
            name: "ReviewUI",
            targets: ["ReviewUI"]
        ),
        .library(
            name: "TextTransitions",
            targets: ["TextTransitions"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.1"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", .upToNextMinor(from: "0.12.0")),
    ],
    targets: [
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
            name: "CodexAppServerKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexAppServerKitTesting",
            dependencies: [
                "CodexAppServerKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewAppServer",
            dependencies: [
                "CodexAppServerKit",
                "CodexReviewKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewMCPServer",
            dependencies: [
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
                "ReviewMonitorRendering",
                "TextTransitions",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewMonitorRendering",
            dependencies: [
                "CodexReviewKit",
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
            ]
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
            dependencies: ["CodexAppServerKit", "CodexReviewAppServer", "CodexReviewHost", "CodexReviewTesting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewUITests",
            dependencies: [
                "CodexReviewKit",
                "CodexReviewTesting",
                "ReviewUI",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewMonitorRenderingTests",
            dependencies: [
                "CodexReviewKit",
                "ReviewMonitorRendering",
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
