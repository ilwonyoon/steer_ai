// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SteerMac",
    platforms: [
        // macOS 26 is the floor: the app's chrome relies on the
        // Liquid Glass material (`.glassEffect`) introduced in
        // macOS 26. swift-tools-version 6.0 doesn't yet expose
        // `.v26` as a symbolic platform version, so we pass the
        // raw string — SwiftPM still threads this through to the
        // -target deployment-version flag correctly.
        .macOS("26.0")
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
        )
        // No testTarget here. SwiftPM implicitly threads `@testable
        // import SteerMac` against the executable target into the
        // launch graph; the resulting .app crashes on first launch
        // inside UNUserNotificationCenter.current() with
        // `bundleProxyForCurrentProcess is nil`. The Mac perf harness
        // belongs in a separate library target, or in a Swift
        // command-line target that doesn't drive the SwiftUI App
        // entry point.
    ]
)
