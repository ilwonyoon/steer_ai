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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(path: "../../packages/SteerCore")
    ],
    targets: [
        .executableTarget(
            name: "SteerMac",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SteerCore", package: "SteerCore")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SteerMacTests",
            dependencies: ["SteerMac"]
        )
    ]
)
