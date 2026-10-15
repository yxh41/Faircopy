// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ColorfulX",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .macCatalyst(.v14),
        .tvOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "ColorfulX", targets: ["ColorfulX"]),
    ],
    dependencies: [
        .package(path: "../ColorVector"),
        .package(path: "../SpringInterpolation"),
        .package(path: "../MSDisplayLink"),
    ],
    targets: [
        .target(
            name: "ColorfulX",
            dependencies: [
                "ColorVector",
                "SpringInterpolation",
                "MSDisplayLink",
            ]
        ),
    ]
)
