// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SteerCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SteerCore", targets: ["SteerCore"])
    ],
    targets: [
        .target(name: "SteerCore")
    ]
)
