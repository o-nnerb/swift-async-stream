[![Swift Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fo-nnerb%2Fswift-async-stream%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/o-nnerb/swift-async-stream)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fo-nnerb%2Fswift-async-stream%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/o-nnerb/swift-async-stream)

# Swift Async Stream

Concurrency primitives and multi-subscriber subjects for Swift's async/await, built on a single
suspension primitive and a single locking primitive.

The standard library and [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
cover operators and single-consumer channels. This package covers what sits underneath them:
mutual exclusion, events, permits, coalescing, and Combine style subjects that broadcast to every
subscriber at once.

It deliberately does not reimplement operators. Reach for swift-async-algorithms for `map`,
`debounce`, `combineLatest` and friends, and use `eraseToAnyAsyncSequence()` to connect the two.

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

## Primitives

### `AsyncLock`

Mutual exclusion for async code. Only one task at a time inside the block, FIFO ordering.

```swift
let lock = AsyncLock()

let session = try await lock.withLock {
    try await refreshSession()
}
```

`lock()` and `unlock()` are available for cases the closure form cannot express, with the usual
caveat that you now own the release.

Not reentrant. Calling `withLock` from inside a `withLock` on the same instance deadlocks.

### `AsyncSemaphore`

A counting semaphore. Bounded concurrency, FIFO ordering, permits handed straight to the next
waiter rather than released into a count they have to race for.

```swift
let semaphore = AsyncSemaphore(permits: 4)

await withTaskGroup(of: Void.self) { group in
    for url in urls {
        group.addTask {
            await semaphore.withPermitVoid {
                await download(url)
            }
        }
    }
}
```

Do not start it at zero permits and use it as an event. That removes the release guarantee the
transparent cancellation contract rests on. `AsyncSignal` is the right tool for that.

### `AsyncSignal`

A manual reset event. Everyone waiting is released at once.

```swift
let ready = AsyncSignal()

Task {
    try await ready.wait()
    start()
}

ready.signal()   // releases every waiter
ready.lock()     // closes it again
```

`AsyncSignal(true)` starts open, so `wait()` returns immediately until `lock()` is called.

### `Lock`

The synchronous primitive everything else is built on. `os_unfair_lock` on Apple platforms,
`pthread_mutex` with error checking in debug on Linux, `SRWLOCK` on Windows. Derived from
SwiftNIO.

```swift
let lock = Lock()
let value = lock.withLock { storage.value }
```

Not reentrant, and typed throws propagates the block's error type.

Two rules when building on it. Never hold it across a suspension point. Never resume a
continuation or call back into user code while holding it: compute what has to happen inside the
critical section, release, then act. Every primitive in this package follows that shape, which is
why they return continuations out of their locked sections instead of resuming them inside.

---

## Subjects

Both subjects broadcast to every subscriber. Unlike `AsyncChannel`, a value is not consumed by
whichever iterator gets there first.

### `EventSubject`

Broadcasts values without storing them. Subscribers only receive what is published after they
subscribe.

```swift
let subject = EventSubject<Int>()

Task {
    for await value in subject {
        print(value)
    }
}

subject.send(42)
subject.send(100)
subject.completed()
```

> Renamed from `PassthroughSubject` in 2.0 to stop colliding with Combine.

### `ValueSubject`

Holds a current value and replays it to each new subscriber.

```swift
let subject = ValueSubject(1)

Task {
    for await value in subject {
        print(value)
    }
}

subject.value = 2
print(subject.value)   // 2
```

Reading `value` cannot fail. The current value is stored alongside the chain rather than read
back out of it.

### Buffering policy

Elements live in a chain that every subscriber walks forward, so the chain can only be released
once the slowest subscriber moves past it. Without a bound, one stalled subscriber pins every
element published since it stalled.

```swift
let frames = EventSubject<Frame>(bufferingPolicy: .bufferingNewest(64))
```

A subscriber that falls past the limit is woken and skips forward, observing a gap rather than
stalling. The producer never suspends.

`.bufferingNewest(1)` on a `ValueSubject` makes it conflating: a slow subscriber always jumps
straight to the latest value.

```swift
let state = ValueSubject(initial, bufferingPolicy: .bufferingNewest(1))
```

The default is `.unbounded`, which is correct when every subscriber must see every value and you
control how long they can stall. There is no `.bufferingOldest`: for a broadcast subject it would
mean hiding the newest value from subscribers that are up to date.

### Type erasure

```swift
let sequence = subject.eraseToAnyAsyncSequence()
```

`AnyAsyncSequence` hides the concrete type. Each call to `makeAsyncIterator()` produces an
independent iterator, so multiple consumers of one erased sequence receive the same elements
rather than competing for them.

It does not break reference cycles. The erased value retains the source, so apply the usual
ownership rules when storing one on an object the subject can reach.

---

## Utilities

### `withTaskTimeout`

Runs an operation under a deadline. Structured, so cancelling the caller cancels both the
operation and the deadline, and whichever finishes first cancels the other.

```swift
do {
    let profile = try await withTaskTimeout(seconds: 5) {
        try await api.loadProfile()
    }
} catch is TaskTimeoutError {
    // the deadline passed
} catch is CancellationError {
    // the caller was cancelled
}
```

`TaskTimeoutError` is distinct from `CancellationError` on purpose. Only one of the two is a
candidate for a retry.

### `SerialCoalescingQueue`

Serializes submissions and collapses adjacent runs of equal jobs into one execution. Ten callers
asking for the same refresh at the same time produce one network call and ten results.

```swift
enum RefreshJob: CoalescingJob {
    case session
    case profile(id: String)
}

let queue = SerialCoalescingQueue<RefreshJob, Profile>()

let profile = try await queue.submit(.profile(id: id)) { job in
    try await api.load(job)
}
```

Equality is the whole policy. Variants that must not share an execution simply have to compare
unequal, and `isCoalescable` opts a type out entirely.

Two contracts worth knowing. `operation` must be a function of `job`, because when two
submissions coalesce only the first closure runs. And the queue is serial with no reentrancy: an
operation that submits back into the same queue deadlocks.

---

## Testing

`SwiftAsyncTesting` provides `AsyncExpectation`, the equivalent of `XCTestExpectation` that Swift
Testing does not ship.

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

Works with both Swift Testing and XCTest, failing through `Issue.record` or `XCTFail` at the
source location where the expectation was created.

A timeout throws `AsyncExpectationTimeout`, which names the expectation, where it was created,
and how many fulfillments arrived out of how many were expected.

### Inverted expectations

```swift
let expectation = AsyncExpectation()
expectation.isInverted = true

try await expectations([expectation], timeout: 0.2)
```

An inverted expectation that is fulfilled fails immediately. One that is never fulfilled can only
be confirmed by waiting the timeout out, so pass a short explicit timeout instead of relying on
the 60 second default.

---

## Debugging

Every primitive that can hold a task describes itself, naming the call site that is holding it
rather than leaving you with an anonymous suspended task.

```swift
print(lock.debugDescription)
```

```
AsyncLock
holder: refreshSession() at NaturaSessionManager.swift:214
pending (2):
  - waiting (selectAddress(_:) at NaturaAddressManager.swift:88)
  - waiting (refreshSession() at NaturaSessionManager.swift:214)
```

A repeat of the same call site in both the holder and the queue is reentrancy.

`SerialCoalescingQueue` exposes the same through `await queue.debugDescription`, including the
dispatched batch, which is otherwise invisible because it has already left the queue.

### Watchdog

A lock that stops being released produces no error, no crash and no log, only tasks that quietly
stop making progress. `AsyncLock` can be asked to say something instead.

```swift
let lock = AsyncLock(
    watchdog: .init(seconds: 2) { Issue.record(Comment(rawValue: $0)) }
)
```

The report carries the full `debugDescription`. Opt-in, and disabled by default at zero cost.

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
