// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftAsyncStream",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8)
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
            name: "SwiftAsyncStream"
        ),
        .target(
            name: "SwiftAsyncTesting",
            dependencies: ["SwiftAsyncStream"]
        ),
        .testTarget(
            name: "SwiftAsyncStreamTests",
            dependencies: ["SwiftAsyncStream", "SwiftAsyncTesting"]
        ),
        .testTarget(
            name: "SwiftAsyncTestingTests",
            dependencies: ["SwiftAsyncTesting"]
        )
    ],
    swiftLanguageModes: [.v6]
)
