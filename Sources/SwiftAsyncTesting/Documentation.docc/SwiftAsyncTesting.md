# ``SwiftAsyncTesting``

`AsyncExpectation`, the equivalent of `XCTestExpectation` that Swift Testing does not ship.

@Metadata {

    @PageColor(green)

    @Available(macOS, introduced: "12.0")
    @Available(iOS, introduced: "15.0")
    @Available(tvOS, introduced: "15.0")
    @Available(watchOS, introduced: "8.0")
    @Available("Swift", introduced: "6.2")

    @SupportedLanguage(swift)
}

## Overview

``SwiftAsyncTesting`` lets a test wait for a known number of asynchronous events instead of
guessing at a `Task.sleep`. It works with both Swift Testing and XCTest, failing through
`Issue.record` or `XCTFail` at the source location where the expectation was created.

```swift
import SwiftAsyncTesting

@Test
func publishesEveryValue() async throws {
    let expectation = AsyncExpectation()
    expectation.expectedFulfillmentCount = 3

    Task {
        for await _ in subject {
            expectation.fulfill()
        }
    }

    subject.send(1)
    subject.send(2)
    subject.send(3)

    try await expectations([expectation], timeout: 1)
}
```

A timeout throws ``AsyncExpectationTimeout``, which names the expectation, where it was created,
and how many fulfillments arrived out of how many were expected.

### Inverted expectations

An expectation can be flipped to fail immediately if it is ever fulfilled:

```swift
let expectation = AsyncExpectation()
expectation.isInverted = true

try await expectations([expectation], timeout: 0.2)
```

One that is never fulfilled can only be confirmed by waiting the timeout out, so pass a short
explicit timeout instead of relying on the 60 second default.

## Topics

### Expectations

- ``AsyncExpectation``
- ``expectations(_:timeout:)``

### Errors

- ``AsyncExpectationTimeout``
