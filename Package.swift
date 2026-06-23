// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "CodexReview",
            targets: ["CodexReview"]
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
            name: "CodexReviewDomain",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewApplication",
            dependencies: [
                "CodexReviewDomain",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReview",
            dependencies: [
                "CodexReviewApplication",
                "CodexReviewDomain",
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
            name: "CodexReviewAppServerWire",
            dependencies: [
                "CodexReviewDomain",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewAppServer",
            dependencies: [
                "CodexAppServerKit",
                "CodexReview",
                "CodexReviewAppServerWire",
                "CodexReviewDomain",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewMCPAdapter",
            dependencies: [
                "CodexReviewDomain",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewMCPServer",
            dependencies: [
                "CodexReview",
                "CodexReviewMCPAdapter",
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
                "CodexReview",
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
                "CodexReview",
                "CodexReviewAppServer",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewUI",
            dependencies: [
                "CodexReview",
                "CodexReviewDomain",
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
                "CodexReviewDomain",
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
            name: "CodexReviewDomainTests",
            dependencies: [
                "CodexReviewDomain",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewApplicationTests",
            dependencies: [
                "CodexReviewApplication",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewAppServerWireTests",
            dependencies: [
                "CodexReviewAppServerWire",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewMCPAdapterTests",
            dependencies: [
                "CodexReviewMCPAdapter",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewTests",
            dependencies: ["CodexReview", "CodexReviewDomain", "CodexReviewTesting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewAppServerTests",
            dependencies: ["CodexAppServerKit", "CodexReviewAppServer", "CodexReviewDomain", "CodexReviewTesting"],
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
                "CodexReview",
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
                "CodexReviewDomain",
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
        .testTarget(
            name: "ArchitectureFenceTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
