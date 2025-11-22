// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftAsyncStream",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
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
            name: "SwiftAsyncStream"
        ),
        .target(
            name: "SwiftAsyncTesting",
            dependencies: ["SwiftAsyncStream"]
        ),
        .testTarget(
            name: "SwiftAsyncStreamTests",
            dependencies: ["SwiftAsyncStream"]
        ),
        .testTarget(
            name: "SwiftAsyncTestingTests",
            dependencies: ["SwiftAsyncTesting"]
        )
    ]
)
