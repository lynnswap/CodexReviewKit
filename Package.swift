// swift-tools-version: 6.3

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
let localCodexKitPath = packageDirectory
    .appendingPathComponent("dependencies/CodexKit", isDirectory: true)
    .path
let codexKitFallbackRevision = "ee38d1b4f3a7c6208434ae57e039050fb2f30f3f"
let codexKitDependency: Package.Dependency =
    FileManager.default.fileExists(atPath: "\(localCodexKitPath)/Package.swift")
        ? .package(path: localCodexKitPath)
        : .package(url: "https://github.com/lynnswap/CodexKit.git", revision: codexKitFallbackRevision)

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
        codexKitDependency,
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
            name: "CodexReviewAppServer",
            dependencies: [
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
                "CodexReviewKit",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewMCPServer",
            dependencies: [
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
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
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
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
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexAppServerKitTesting", package: "CodexKit"),
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
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
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
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewUIPreviewSupport",
            dependencies: [
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
                .product(name: "CodexAppServerKitTesting", package: "CodexKit"),
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
            name: "CodexReviewKitTests",
            dependencies: ["CodexReviewKit", "CodexReviewTesting"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewAppServerTests",
            dependencies: [
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexAppServerKitTesting", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
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
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
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
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexAppServerKitTesting", package: "CodexKit"),
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
                .product(name: "CodexAppServerKit", package: "CodexKit"),
                .product(name: "CodexDataKit", package: "CodexKit"),
                .product(name: "CodexAppServerKitTesting", package: "CodexKit"),
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
