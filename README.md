# Swift Async Stream Utilities

This repository contains experimental implementations of `AsyncSignal`, `ValueSubject`, and `PassthroughSubject` for Swift. These utilities provide reactive programming capabilities that are not currently available in Swift or in the official [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) repository.

## Overview

The Swift standard library and the official async algorithms package don't provide equivalents to reactive programming utilities like `ValueSubject` and `PassthroughSubject` found in Combine. This repository fills that gap by providing implementations that work with Swift's async/await system.

### Key Features

- **ValueSubject**: A subject that holds a value and emits the current value to new subscribers
- **PassthroughSubject**: A subject that broadcasts values to all subscribers without storing a current value
- **AsyncSignal**: An experimental signal implementation
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
await valueSubject.send(2)
await valueSubject.send(3)
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
await passthroughSubject.send(42)
await passthroughSubject.send(100)
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
await valueSubject.send(5)
```

## Purpose

This repository serves as a study material and a way to share possibilities with the community. It demonstrates how to implement reactive programming patterns in Swift's async ecosystem, providing functionality similar to Combine's subjects but adapted for async sequences.

## License

This project is available for study and experimentation purposes.