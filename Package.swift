// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftAsyncStream",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(
            name: "SwiftAsyncStream",
            targets: ["SwiftAsyncStream"]
        ),
        .library(
            name: "SwiftAsyncTesting",
            targets: ["SwiftAsyncTesting"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftAsyncStream",
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .target(
            name: "SwiftAsyncTesting",
            dependencies: ["SwiftAsyncStream"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "SwiftAsyncStreamTests",
            dependencies: ["SwiftAsyncStream", "SwiftAsyncTesting"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "SwiftAsyncTestingTests",
            dependencies: ["SwiftAsyncTesting"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
