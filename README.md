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

All three broadcast to every subscriber. Unlike `AsyncChannel`, a value is not consumed by
whichever iterator gets there first.

They are the same machinery with one difference: where a new subscriber joins the chain of
published elements.

| Subject | Joins at | Sees |
|---|---|---|
| `EventSubject` | the tail | only what is published after it subscribes |
| `ValueSubject` | the latest element | the current value, then everything after |
| `ReplaySubject` | the head | everything still buffered, then everything after |

### `EventSubject`

Broadcasts values without storing them.

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

### `ReplaySubject`

Replays what it still holds to every new subscriber, then continues live.

```swift
let subject = ReplaySubject<Int>(bufferingPolicy: .bufferingNewest(10))

subject.send(1)
subject.send(2)

for await value in subject {   // receives 1, 2, then whatever follows
    print(value)
}
```

`bufferingPolicy` has no default here, unlike the other two. They only retain elements while a
subscriber is behind, so a reader that keeps up lets them go. This one is obliged to hold its
window whether anyone is reading or not, which makes `.unbounded` a commitment to grow for the
lifetime of the subject rather than a mild default. The choice belongs at the call site.

---

## Buffering policy

Elements live in a chain that every subscriber walks forward, so the chain can only be released
once the slowest subscriber moves past it. Without a bound, one stalled subscriber pins every
element published since it stalled.

| Policy | `EventSubject` / `ValueSubject` | `ReplaySubject` |
|---|---|---|
| `.unbounded` | default | supported |
| `.bufferingNewest(n)` | supported | supported |
| `.untilFirstIteration` | traps at init | supported, single use |

### `.bufferingNewest(n)`

Keeps at most `n` elements, discarding the oldest first.

```swift
let frames = EventSubject<Frame>(bufferingPolicy: .bufferingNewest(64))
```

A subscriber that falls past the limit is woken and skips forward, observing a gap rather than
stalling. The producer never suspends.

On a `ValueSubject`, `.bufferingNewest(1)` makes it conflating: a slow subscriber always jumps
straight to the latest value. On a `ReplaySubject` it means "replay the last n".

There is no `.bufferingOldest`. For a broadcast subject it would mean hiding the newest value
from subscribers that are up to date, which is the opposite of the point.

### `.untilFirstIteration`

Keeps everything until the first iterator is created, then hands the buffer to that consumer and
stops holding anything.

```swift
let body = ReplaySubject<Data>(bufferingPolicy: .untilFirstIteration)
```

This is for the common shape where a subject has to tolerate a late first reader but is only ever
read once. A response body is the canonical case: bytes start arriving long before the caller
reaches for them, so nothing can be dropped up front, but once reading starts there is no reason
to keep what has already been consumed. Retained memory goes from "everything ever published" to
"the gap between producer and reader".

The prefix kept before the first iteration is unbounded. Capping it would discard exactly what the
mode exists to preserve.

**Single use.** A second iterator has nothing left to replay, so `makeAsyncIterator()` traps
rather than quietly handing back whatever survived, which would be a partial result that varies
with how far the first reader got.

A wrapper with an error channel of its own can report the misuse instead:

```swift
func makeAsyncIterator() -> AsyncIterator {
    guard let iterator = subject.makeIteratorIfAvailable() else {
        return .init(failing: AlreadyConsumedError())
    }

    return .init(iterator)
}
```

`makeIteratorIfAvailable()` returns `nil` only under this policy, and only after the handover.

Only `ReplaySubject` can honour it. The other subjects join at the tail or at the latest element,
never at the head, so they would hold the buffer forever and never release it. Passing it to them
traps at construction.

---

## Type erasure

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

### `FIFOQueue`

A first in, first out queue with amortized constant time at both ends, and the one the primitives
above use for their waiter lists.

```swift
var queue = FIFOQueue<Job>()

queue.append(job)

while let job = queue.popFirst() {
    run(job)
}
```

`Array` is quadratic for this: `removeFirst()` shifts everything left, and `insert(at: 0)` shifts
everything right. Here the front is a cursor that only moves forward, and the storage is rebuilt
only once enough of it has gone dead. Vacated slots are cleared, so a dequeued element is released
immediately rather than lingering until the next compaction, which matters when the elements are
closures or objects holding onto something expensive.

No synchronization of its own. Guard it the way you would guard an `Array`.

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

### Deterministic queue shapes

Creating a `Task` schedules it, it does not run it, so a test that needs a known queue order has
to admit one waiter at a time and confirm each arrival. `AsyncLock`, `AsyncSemaphore` and
`SerialCoalescingQueue` expose that under `@_spi(Testing)`:

```swift
@_spi(Testing) import SwiftAsyncStream

for index in 0..<10 {
    tasks.append(Task { await lock.withLockVoid { order.append(index) } })
    try await lock.waitForPendingOperations(index + 1)
}
```

---

## Debugging

Every primitive that can hold a task describes itself, naming the call site that is holding it
rather than leaving you with an anonymous suspended task.

```swift
print(lock.debugDescription)
```

```
AsyncLock
holder: refreshSession() at SessionManager.swift:214
pending (2):
  - waiting (selectAddress(_:) at AddressManager.swift:88)
  - waiting (refreshSession() at SessionManager.swift:214)
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
