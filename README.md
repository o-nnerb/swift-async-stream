    [![Swift Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fo-nnerb%2Fswift-async-stream%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/o-nnerb/swift-async-stream)
    [![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fo-nnerb%2Fswift-async-stream%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/o-nnerb/swift-async-stream)

# Swift Async Stream Utilities

This repository contains experimental implementations of `AsyncSignal`, `ValueSubject`, and `PassthroughSubject` for Swift. These utilities provide reactive programming capabilities that are not currently available in Swift or in the official [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) repository.

## Overview

The Swift standard library and the official async algorithms package don't provide equivalents to reactive programming utilities like `ValueSubject` and `PassthroughSubject` found in Combine. This repository fills that gap by providing implementations that work with Swift's async/await system.

### Key Features

- **ValueSubject**: A subject that holds a value and emits the current value to new subscribers
- **PassthroughSubject**: A subject that broadcasts values to all subscribers without storing a current value
- **AsyncSignal**: An experimental signal implementation
- **AsyncExpectation**: An equivalent to the `XCTestExpectation` functionality for Swift Testing
- **Multi-subscriber support**: Unlike `AsyncChannel` from swift-async-algorithms, these subjects can share values with multiple subscribers simultaneously

## Usage

### ValueSubject

```swift
let valueSubject = ValueSubject(1)

Task {
    for await index in valueSubject {
        print("Received value: \(index)")
    }
}

// Send new values
valueSubject.value = 2
valueSubject.value = 3
```

### PassthroughSubject

```swift
let passthroughSubject = PassthroughSubject<Int, Never>()

Task {
    for await value in passthroughSubject {
        print("Received value: \(value)")
    }
}

// Send values
passthroughSubject.send(42)
passthroughSubject.send(100)
```

## Memory Management

To avoid memory reference cycles between subscribers and subjects, it's recommended to use `.eraseToAnyAsyncSequence()` when passing subjects around:

```swift
let valueSubject = ValueSubject(1)

// Recommended approach
let erasedSubject = valueSubject.eraseToAnyAsyncSequence()

Task {
    for await index in erasedSubject {
        print("Received value: \(index)")
    }
}
```

This approach prevents retain cycles between the subscriber and the subject.

## Multi-subscriber Support

Unlike `AsyncChannel` from the swift-async-algorithms repository, which only shares values with a single subscriber, both `ValueSubject` and `PassthroughSubject` support multiple subscribers simultaneously:

```swift
let valueSubject = ValueSubject(1)

// Multiple tasks can subscribe to the same subject
Task {
    for await value in valueSubject {
        print("Task 1 received: \(value)")
    }
}

Task {
    for await value in valueSubject {
        print("Task 2 received: \(value)")
    }
}

// Both tasks will receive the same values
                                                                                                                                                                                                                                                                            valueSubject.value = 5
```

## AsyncExpectation

In addition to the reactive programming utilities, this repository also includes `AsyncExpectation`, which addresses a significant gap in Swift Testing. The Swift Testing framework currently lacks an equivalent to the `XCTestExpectation` functionality that XCTest provides.

### The Problem

When writing asynchronous tests, developers often need to wait for specific conditions or events to occur before continuing with the test. In XCTest, this is commonly handled with `XCTestExpectation`:

```swift
func testAsyncOperation() async {
    let expectation = XCTestExpectation(description: "Async operation completes")

    // Perform async operation that calls expectation.fulfill() when done

    wait(for: [expectation], timeout: 10.0)
}
```

However, Swift Testing doesn't provide a similar mechanism, making it difficult to write tests that need to wait for asynchronous events.

### The Solution

`AsyncExpectation` fills this gap by providing similar functionality for Swift Testing:

```swift
import SwiftAsyncTesting

func testAsyncOperation() async throws {
    let expectation = AsyncExpectation(description: "Async operation completes")

    Task {
        // Perform some async operation
        await someAsyncFunction()
        expectation.fulfill()  // Signal that the condition is met
    }

    // Wait for the expectation to be fulfilled
    try await expectations([expectation], timeout: 10.0)
}
```

### Key Features

- **Compatibility**: Works with both Swift Testing and XCTest frameworks
- **Timeout Support**: Built-in timeout functionality to prevent hanging tests
- **Multiple Expectations**: Ability to wait for multiple expectations simultaneously
- **Inverted Expectations**: Support for inverted expectations that fail if fulfilled
- **Thread-Safe**: Safe to use across different tasks and threads

## Purpose

This repository serves as a study material and a way to share possibilities with the community. It demonstrates how to implement reactive programming patterns in Swift's async ecosystem, providing functionality similar to Combine's subjects but adapted for async sequences. Additionally, it addresses the missing expectation functionality in Swift Testing, offering a solution similar to XCTest/expectation for asynchronous testing scenarios.

## License

This project is available for study and experimentation purposes.
