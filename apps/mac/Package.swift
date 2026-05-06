// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SteerMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "SteerMac", targets: ["SteerMac"])
    ],
    targets: [
        .executableTarget(
            name: "SteerMac",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
