// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewKitProductConsumer",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "CodexReviewKitProductConsumer",
            dependencies: [
                .product(name: "CodexReview", package: "CodexReviewKit"),
                .product(name: "CodexReviewHost", package: "CodexReviewKit"),
                .product(name: "ReviewUI", package: "CodexReviewKit"),
                .product(name: "TextTransitions", package: "CodexReviewKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
