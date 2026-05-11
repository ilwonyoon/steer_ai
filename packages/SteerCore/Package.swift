// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SteerCore",
    platforms: [
        // Match SteerMac (.macOS 26) — the Mac app's Liquid Glass
        // dependency drags the SteerCore floor up. iOS stays at 17
        // so older devices can still install the app from TestFlight.
        .macOS("26.0"),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SteerCore", targets: ["SteerCore"])
    ],
    targets: [
        .target(name: "SteerCore"),
        .testTarget(name: "SteerCoreTests", dependencies: ["SteerCore"])
    ]
)
