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
            name: "ReviewUI",
            targets: ["ReviewUI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.1"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", .upToNextMinor(from: "0.10.0")),
    ],
    targets: [
        .target(
            name: "CodexReview",
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
                "CodexReview",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewMCPServer",
            dependencies: [
                "CodexReview",
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
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewTests",
            dependencies: ["CodexReview", "CodexReviewTesting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewAppServerTests",
            dependencies: ["CodexReviewAppServer", "CodexReviewTesting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewMCPServerTests",
            dependencies: ["CodexReviewMCPServer", "CodexReviewTesting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewHostTests",
            dependencies: ["CodexReviewAppServer", "CodexReviewHost", "CodexReviewTesting"],
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
            name: "ArchitectureFenceTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
