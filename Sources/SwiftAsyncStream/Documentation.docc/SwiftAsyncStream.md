# ``SwiftAsyncStream``

Concurrency primitives and multi-subscriber subjects for Swift's async/await, built on a single
suspension primitive and a single locking primitive.

@Metadata {

    @PageColor(purple)

    @Available(macOS, introduced: "12.0")
    @Available(iOS, introduced: "15.0")
    @Available(tvOS, introduced: "15.0")
    @Available(watchOS, introduced: "8.0")
    @Available("Swift", introduced: "6.2")

    @SupportedLanguage(swift)
}

## Overview

The standard library and [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
cover operators and single-consumer channels. ``SwiftAsyncStream`` covers what sits underneath
them: mutual exclusion, events, permits, coalescing, and Combine style subjects that broadcast to
every subscriber at once.

It deliberately does not reimplement operators. Reach for swift-async-algorithms for `map`,
`debounce`, `combineLatest` and friends, and use `eraseToAnyAsyncSequence()` to connect the two,
see ``AnyAsyncSequence``.

### The cancellation contract

Read this before anything else. It is the single design rule the whole package turns on:

**A primitive whose release is guaranteed is cancellation transparent. A primitive whose release
is not guaranteed must be cancellable.**

Cancellation in Swift is cooperative: it never resumes a suspended continuation on its own. So a
primitive has exactly two honest options when a waiter is cancelled. It can leave the waiter in
the queue, which is safe only if the queue is guaranteed to drain (``AsyncLock``,
``AsyncSemaphore``). Or it can pull the waiter out and resume it with `CancellationError`, which
is what ``AsyncSignal`` and ``SerialCoalescingQueue`` do.

Under a transparent contract a cancelled task still takes its turn and runs. Check for
cancellation inside the critical section if that matters:

```swift
try await lock.withLock {
    try Task.checkCancellation()
    return try await work()
}
```

## Topics

### Mutual exclusion

- ``Lock``
- ``AsyncLock``

### Coordination

- ``AsyncSemaphore``
- ``AsyncSignal``
- ``SerialCoalescingQueue``
- ``CoalescingJob``

### Subjects

Broadcast to every subscriber at once, unlike `AsyncChannel`, where a value is consumed by
whichever iterator gets there first.

- ``EventSubject``
- ``ValueSubject``
- ``ReplaySubject``
- ``SubjectBufferingPolicy``
- ``SubjectAsyncIterator``

### Type erasure

- ``AnyAsyncSequence``

### Utilities

- ``withTaskTimeout(seconds:of:body:)``
- ``TaskTimeoutError``
- ``FIFOQueue``
- ``InlineProperty``
