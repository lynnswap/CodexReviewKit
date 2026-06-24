// swift-tools-version: 6.3

import Foundation
import PackageDescription

private let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
private let codexKitDevelopmentPath = "dependencies/CodexKit"
private let codexKitDevelopmentManifestPath = packageDirectory
    .appendingPathComponent(codexKitDevelopmentPath)
    .appendingPathComponent("Package.swift")
    .path
private let codexKitDependency: Package.Dependency = {
    if FileManager.default.fileExists(atPath: codexKitDevelopmentManifestPath) {
        // Development-only CodexKit integration checkout. Keep the local CodexKit
        // worktree at dependencies/CodexKit while this branch tracks in-flight APIs.
        return .package(path: codexKitDevelopmentPath)
    }

    // Fresh checkouts and CI must not depend on an ignored local checkout. Until
    // CodexKit is released, fall back to the pinned integration revision; replace
    // this with the final pinned remote CodexKit release dependency before release.
    return .package(
        url: "https://github.com/lynnswap/CodexKit.git",
        revision: "09ad955e2d638a0287cbb4a2165214f8f8fa3dfb"
    )
}()

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
            name: "TextTransitions",
            targets: ["TextTransitions"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
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
                .product(name: "CodexAppServerKit", package: "CodexKit"),
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
