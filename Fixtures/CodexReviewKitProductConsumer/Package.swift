// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewKitProductConsumer",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(
            name: "CodexReviewKitProductConsumer",
            targets: ["CodexReviewKitProductConsumer"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "CodexReviewKitProductConsumer",
            dependencies: [
                .product(name: "CodexAppServerKit", package: "CodexReviewKit"),
                .product(name: "CodexAppServerKitTesting", package: "CodexReviewKit"),
                .product(name: "CodexDataKit", package: "CodexReviewKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
