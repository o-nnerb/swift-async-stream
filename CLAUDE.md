# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SwiftAsyncStream is a Swift package of concurrency primitives and multi-subscriber subjects for
async/await: mutual exclusion, events, permits, coalescing, and Combine-style broadcast subjects.
It deliberately does not reimplement sequence operators (`map`, `debounce`, etc.) — those belong to
swift-async-algorithms; use `eraseToAnyAsyncSequence()` to bridge into that world.

No dependencies, not even Foundation (Linux linkage is checked in CI to enforce this — see below).
Swift tools 6.2, language mode 6. Platforms: iOS 15, macOS 12, tvOS 15, watchOS 8, Linux, Windows.

Two library products/targets, each with its own test target:
- `SwiftAsyncStream` — the core primitives, tested by `SwiftAsyncStreamTests`
- `SwiftAsyncTesting` — depends on `SwiftAsyncStream`, tested by `SwiftAsyncTestingTests`

## Commands

```bash
swift build                                    # build
swift test                                     # run all tests
swift test --filter AsyncLockTests             # run one test target/class
swift test --filter AsyncLockTests/testFIFOOrder  # run one test
swift format lint --strict --recursive --configuration .swift-format .   # lint (CI-enforced)
swift format --in-place --recursive --configuration .swift-format .      # auto-fix formatting
```

Stress tests for continuation leaks and watchdog behavior live in
`Tests/SwiftAsyncStreamTests/ContinuationLeakStressTests.swift` and are run separately under
ThreadSanitizer/AddressSanitizer in CI:

```bash
swift test --filter ContinuationLeakStressTests
```

CI (`.github/workflows/swift-ci.yaml`) runs, in order: format check → API breaking-change diagnosis
(`swift package diagnose-api-breaking-changes`, skipped on major-version bumps/tags) → Apple
platform matrix (Xcode/xcodebuild) + Linux (`swift test`) + a Linux linkage test asserting the
built binary does **not** link `libFoundation.so` + Thread/Address sanitizer runs → coverage upload
to Codecov. Any source change must stay formatted per `.swift-format` and must not introduce a
Foundation import (use `FoundationEssentials` only if absolutely necessary, never plain
`Foundation`).

## The cancellation contract — read before touching any primitive

This is the single design rule the whole package turns on:

**A primitive whose release is guaranteed is cancellation transparent. A primitive whose release
is not guaranteed must be cancellable (throws `CancellationError`).**

Cancellation in Swift is cooperative — it never resumes a suspended continuation on its own. So
every primitive has exactly two honest choices: leave a cancelled waiter in the queue (safe only if
the queue is guaranteed to drain), or pull it out and resume it with an error. There is no
non-throwing early-out; attempting one leaves a continuation nobody resumes — a task stuck forever
with no error, no crash, no log.

| Primitive | Waiting is | Because |
|---|---|---|
| `AsyncLock` | transparent | the holder always releases through `defer` |
| `AsyncSemaphore` | transparent | the permit always comes back through `defer` |
| `AsyncSignal` | cancellable, throws | nothing guarantees `signal()` ever arrives |
| `SerialCoalescingQueue` | cancellable, throws | a waiter can leave before dispatch |
| Subjects | terminate the sequence | `next()` returns `nil`, `for await` exits |

When adding or modifying a primitive, classify it against this table first and match its
cancellation behavior accordingly — do not invent a third option.

## Architecture

### Layering

```
Lock (sync, platform primitive)
  └─ AsyncLock, AsyncSemaphore, AsyncSignal, SerialCoalescingQueue (async primitives)
        └─ NodeSubject / NodeChain (broadcast machinery, built on AsyncSignal + Lock)
              └─ EventSubject, ValueSubject, ReplaySubject (public subject API)
```

- **`Lock`** (`Sources/SwiftAsyncStream/Lock.swift`) is the one synchronous primitive everything
  else is built on: `os_unfair_lock` on Apple platforms, `pthread_mutex` (error-checking in debug)
  on Linux, `SRWLOCK` on Windows. Derived from SwiftNIO. Two rules for anything built on it: never
  hold it across a suspension point, and never resume a continuation or call back into user code
  while holding it — compute what must happen inside the critical section, release the lock, then
  act. Every async primitive in this package follows that shape, returning continuations out of
  locked sections instead of resuming them inside.
- **`FIFOQueue`** (`Sources/SwiftAsyncStream/FIFOQueue.swift`) backs the waiter lists of the async
  primitives. It exists because `Array.removeFirst()`/`insert(at: 0)` are O(n); this is a
  cursor-based queue with amortized O(1) at both ends and eager release of dequeued slots.
- **`PendingWaitersTimeout`** (`Sources/SwiftAsyncStream/Async/PendingWaitersTimeout.swift`)
  implements the shared watchdog mechanism (used by `AsyncLock`) that reports a debug description
  when a waiter has been stuck past a deadline, without failing anything itself.

### Subjects share one machinery

`EventSubject`, `ValueSubject`, and `ReplaySubject` (`Sources/SwiftAsyncStream/Stream/`) are the
same underlying chain with only one difference: where a new subscriber joins.

- **`NodeSubject`** is a single cell in a singly linked chain of published elements. Each cell owns
  its element, an `AsyncSignal` (`producer`) that releases consumers parked on it, and a strong
  reference to its successor. State transitions (`waiting` → `produced`/`dropped` → `completed`)
  and the successor link are read/written together under one `Lock` via a `Snapshot`, because
  reading them separately could observe a cell that produced an element without yet advertising its
  successor.
- Cell teardown is iterative, not recursive (see `NodeSubject.deinit`): releasing the head of a long
  chain through recursive `deinit` calls would overflow the stack, so it walks `_next` in a loop,
  stopping as soon as a cell is still referenced elsewhere (`isKnownUniquelyReferenced`).
- **`NodeChain`** owns where the window into that cell chain starts and how long it is — i.e. the
  buffering policy (`SubjectBufferingPolicy`: `.unbounded`, `.bufferingNewest(n)`,
  `.untilFirstIteration`) is chain-level state, not cell-level.
- Because subscribers only ever move forward through the chain, a stalled subscriber pins every
  element published since it stalled unless a buffering policy bounds the window. `.bufferingNewest`
  wakes a subscriber that falls behind the limit so it skips forward (observing a gap) instead of
  stalling the producer. `.untilFirstIteration` is only valid on `ReplaySubject`, which joins at the
  head — `EventSubject`/`ValueSubject` join at the tail/latest value and would hold the buffer
  forever, so the policy traps at construction on those.
- `SubjectAsyncIterator` is the `AsyncIteratorProtocol` conformance shared across subjects; each
  call to `eraseToAnyAsyncSequence()` (`AnyAsyncSequence`) produces an independent iterator over the
  same chain, so multiple erased consumers see the same elements rather than racing for them. It
  does not break reference cycles — the erased value retains the source.

### Other primitives

- **`AsyncSemaphore`**: FIFO permits handed directly to the next waiter (not released into a count
  waiters race for). Must not be used at zero permits as an ad hoc event — that removes the release
  guarantee the transparent-cancellation contract depends on; use `AsyncSignal` for that instead.
- **`SerialCoalescingQueue`**: jobs conforming to `CoalescingJob` are compared for equality; equal
  adjacent submissions collapse into a single execution of the *first* submitted closure (so
  `operation` must be a pure function of the job value). Serial with no reentrancy — submitting back
  into the same queue from inside an operation deadlocks.
- **`Task+.swift`**: `withTaskTimeout` races an operation against a deadline using structured
  concurrency (cancelling the caller cancels both branches; whichever finishes first cancels the
  other). Throws `TaskTimeoutError` on deadline expiry, distinct from `CancellationError`, since
  only the former is a sane retry signal.
- **`InlineProperty`**: a property wrapper; `withValue(_:)` exists because `wrappedValue += 1` is a
  read-modify-write across three separate atomic operations under concurrency and loses updates —
  compound updates must go through `withValue`.

### Debugging & test-only APIs

- Every primitive that can hold a task implements `debugDescription`, naming the call site holding
  it (via source location capture, not a generic "task suspended" message) plus the pending queue.
  A call site appearing in both holder and queue indicates reentrancy.
- `AsyncLock`, `AsyncSemaphore`, and `SerialCoalescingQueue` expose deterministic-queue-shape
  helpers (e.g. `waitForPendingOperations(_:)`) under `@_spi(Testing)` — needed in tests because
  creating a `Task` only schedules it, so asserting FIFO order requires admitting one waiter at a
  time and confirming arrival before adding the next. Import with `@_spi(Testing) import
  SwiftAsyncStream` in tests that need this.
- `SwiftAsyncTesting`'s `AsyncExpectation` is the `XCTestExpectation` equivalent Swift Testing does
  not ship; `fulfill()` is atomic, inverted expectations fail fast rather than costing the full
  timeout, and timeouts throw `AsyncExpectationTimeout` (naming the expectation, its creation site,
  and fulfillment count) rather than `CancellationError`.

## Naming/behavior notes that matter for compatibility

- `EventSubject` was `PassthroughSubject` pre-2.0 — renamed to stop colliding with Combine. Don't
  reintroduce that name.
- There is deliberately no `.bufferingOldest` policy — for a broadcast subject it would mean hiding
  the newest value from subscribers that are already caught up, which contradicts the point of a
  broadcast subject.
