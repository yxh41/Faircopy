// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WritingTools",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "WritingTools",
            targets: [
                "WritingTools",
                "WritingToolsInjector",
            ]
        ),
        .library(
            name: "WritingToolsInjector",
            targets: ["WritingToolsInjector"]
        ),
    ],
    dependencies: [
        .package(path: "../ColorfulX"),
        .package(path: "../OpenAI"),
    ],
    targets: [
        .target(name: "WritingToolsLocalizable"),
        .target(
            name: "WritingTools",
            dependencies: [
                "WritingToolsLocalizable",
                "WritingToolsInjector",
                "ColorfulX",
                "OpenAI",
            ]
        ),
        .target(name: "WritingToolsInjector"),
    ]
)
