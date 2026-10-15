// swift-tools-version: 5.6

import PackageDescription

let package = Package(
    name: "ColorVector",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .macCatalyst(.v14),
        .tvOS(.v14),
    ],
    products: [
        .library(name: "ColorVector", targets: ["ColorVector"]),
    ],
    targets: [
        .target(name: "ColorVector"),
    ]
)
