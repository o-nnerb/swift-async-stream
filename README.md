[![Swift Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fo-nnerb%2Fswift-async-stream%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/o-nnerb/swift-async-stream)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fo-nnerb%2Fswift-async-stream%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/o-nnerb/swift-async-stream)
[![codecov](https://codecov.io/gh/o-nnerb/swift-async-stream/graph/badge.svg?token=SePqHpqsiL)](https://codecov.io/gh/o-nnerb/swift-async-stream)

# Swift Async Stream

Concurrency primitives and multi-subscriber subjects for Swift's async/await, built on a single
suspension primitive and a single locking primitive.

The standard library and [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
cover operators and single-consumer channels. This package covers what sits underneath them:
mutual exclusion, events, permits, coalescing, and Combine style subjects that broadcast to every
subscriber at once.

It deliberately does not reimplement operators. Reach for swift-async-algorithms for `map`,
`debounce`, `combineLatest` and friends, and use `eraseToAnyAsyncSequence()` to connect the two.

## [Documentation](https://swiftpackageindex.com/o-nnerb/swift-async-stream/main/documentation/swiftasyncstream)

The full API reference, with every type, method and buffering policy documented in place, is
generated from this repository and hosted by the Swift Package Index. `SwiftAsyncTesting` has
[its own target](https://swiftpackageindex.com/o-nnerb/swift-async-stream/main/documentation/swiftasynctesting)
in the same archive; switch between the two from the sidebar.

## Requirements

| | |
|---|---|
| Swift | 6.2 |
| Language mode | 6 |
| Platforms | iOS 15, macOS 12, tvOS 15, watchOS 8, Linux, Windows |
| Dependencies | none, not even Foundation |

## Installation

```swift
.package(url: "https://github.com/o-nnerb/swift-async-stream.git", from: "2.0.0")
```

```swift
.target(name: "MyTarget", dependencies: [
    .product(name: "SwiftAsyncStream", package: "swift-async-stream")
])

.testTarget(name: "MyTargetTests", dependencies: [
    .product(name: "SwiftAsyncTesting", package: "swift-async-stream")
])
```

---

## The cancellation contract

Read this before anything else. It is the single design rule the whole package turns on, and the
apparent inconsistency between primitives is deliberate.

**A primitive whose release is guaranteed is cancellation transparent. A primitive whose release
is not guaranteed must be cancellable.**

Cancellation in Swift is cooperative: it does not stop a task, and it never resumes a suspended
continuation on its own. So a primitive has exactly two honest options when a waiter is cancelled.
It can leave the waiter in the queue, which is safe only if the queue is guaranteed to drain. Or
it can pull the waiter out and resume it, which requires a way to say "you did not acquire", which
in turn requires throwing.

| Primitive | Waiting is | Because |
|---|---|---|
| `AsyncLock` | transparent | the holder always releases through `defer` |
| `AsyncSemaphore` | transparent | the permit always comes back through `defer` |
| `AsyncSignal` | cancellable, throws `CancellationError` | nothing guarantees `signal()` ever arrives |
| `SerialCoalescingQueue` | cancellable, throws `CancellationError` | a waiter can leave before dispatch |
| Subjects | terminate the sequence | `next()` returns `nil`, the `for await` exits |

Under a transparent contract a cancelled task still takes its turn and runs. Check for
cancellation inside the critical section if that matters:

```swift
try await lock.withLock {
    try Task.checkCancellation()
    return try await work()
}
```

There is no third option. Any attempt to give a non-throwing `lock()` early-out semantics ends
with a continuation that nobody resumes, which is a task suspended forever with no error, no
crash and no log.

---

## Quick tour

Every type below links to its full reference, including buffering policies, type erasure,
debugging, and the `AsyncLock` watchdog, in the [hosted documentation](#documentation).

### Primitives

```swift
let session = try await lock.withLock { try await refreshSession() }

await semaphore.withPermitVoid { await download(url) }   // bounded concurrency

try await ready.wait()   // AsyncSignal, released by ready.signal()
```

`AsyncLock` and `AsyncSemaphore` are not reentrant. `Lock` is the synchronous primitive
everything else is built on.

### Subjects

All three broadcast to every subscriber at once, unlike `AsyncChannel`, where a value is
consumed by whichever iterator gets there first. They differ in where a new subscriber joins.

| Subject | Joins at |
|---|---|
| `EventSubject` | the tail, seeing only what is published after it subscribes |
| `ValueSubject` | the latest element, then everything after |
| `ReplaySubject` | the head, replaying what is still buffered |

```swift
let subject = EventSubject<Int>()

Task {
    for await value in subject {
        print(value)
    }
}

subject.send(42)
```

### Utilities

- `withTaskTimeout` runs an operation under a structured deadline.
- `SerialCoalescingQueue` collapses concurrent identical submissions into one execution.
- `FIFOQueue` is the amortized O(1) queue every primitive above uses for its waiters.

## Testing

`SwiftAsyncTesting` provides `AsyncExpectation`, the equivalent of `XCTestExpectation` that Swift
Testing does not ship. It works with both Swift Testing and XCTest.

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

Inverted expectations, and `@_spi(Testing)` hooks for deterministic queue shapes in `AsyncLock`,
`AsyncSemaphore` and `SerialCoalescingQueue`, are covered in the hosted documentation.

---

## Migration from 1.x

| 1.x | 2.0 |
|---|---|
| `PassthroughSubject` | `EventSubject` |
| `await signal.wait()` | `try await signal.wait()`, throws on cancellation |
| `withTaskTimeout` throwing `CancellationError` on timeout | throws `TaskTimeoutError` |
| `expectations` throwing `CancellationError` on timeout | throws `AsyncExpectationTimeout` |
| `node.stateDataSource` / `node.nextDataSource` | `node.snapshot` |
| `AsyncOperation.State.finished` | `.running` |
| `InlineProperty: Sendable` | conditional on `Value: Sendable` |

Behavioural changes that do not break compilation:

- **A cancelled waiter now terminates.** In 1.x, cancelling a task waiting on `AsyncSignal`, or
  on anything built over it, discarded its continuation and suspended the task permanently. This
  is the reason for most of the rest of this release.
- **`AnyAsyncSequence` no longer shares one iterator.** In 1.x every consumer of an erased
  sequence shared a single iterator and stole elements from each other.
- **`AsyncExpectation.fulfill()` is atomic.** In 1.x concurrent fulfillments could lose an
  increment and leave the expectation waiting for a count that could no longer be reached.
- **Inverted expectations fail fast** instead of costing the full timeout.
- **Foundation is no longer imported.** If your code relied on receiving it transitively, import
  it explicitly.

New in 2.0: `AsyncSemaphore`, `ReplaySubject`, `FIFOQueue`, buffering policies, the `AsyncLock`
watchdog, and `debugDescription` on every primitive that can hold a task.

`InlineProperty` gained `withValue(_:)`. Reads and writes were always individually safe, but they
do not compose: `wrappedValue += 1` is a read, a modify and a write, so concurrent callers lose
updates. Use `withValue { $0 += 1 }` whenever the new value depends on the old one.

Expect the first run after upgrading to surface failures rather than hide them. Tests that passed
in 1.x because a hang was swallowed will now report.

---

## Purpose

This repository started as study material and a way to share possibilities with the community. It
demonstrates how reactive patterns and classic synchronization primitives can be built on Swift
concurrency, and how much of getting them right comes down to one question: who resumes the
continuation, and are they guaranteed to.

## License

Apache 2.0. `Lock` is derived from
[SwiftNIO](https://github.com/apple/swift-nio/blob/main/Sources/NIOConcurrencyHelpers/lock.swift),
also Apache 2.0.
