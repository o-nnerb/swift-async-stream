// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@_spi(Testing) @testable import SwiftAsyncStream

/// Counts finished tasks and signals once they are all in.
///
/// The suite leans on this rather than on `await task.value`, because awaiting an unstructured
/// `Task<Void, Never>` does not respond to cancellation. Wrapping that in `withTaskTimeout`
/// looks like a safety net and is not one: the deadline fires, the group cancels its children,
/// and then hangs draining the one still parked on `value`. Waiting on an `AsyncSignal` throws
/// on cancellation, so the timeout can actually end the test.
private actor CompletionCounter {

    private(set) var count = 0

    private let target: Int
    private let finished: AsyncSignal

    init(target: Int, finished: AsyncSignal) {
        self.target = target
        self.finished = finished
    }

    func increment() {
        count += 1

        if count == target {
            finished.signal()
        }
    }
}

/// A leak here is a task that never resumes, which without a bound shows up as a job the CI
/// killed after an hour rather than as a named failing test. Everything below is bounded, so a
/// dropped continuation fails as `TaskTimeoutError` and says which primitive lost it.
@Suite(.serialized)
struct ContinuationLeakStressTests {

    private static let waiters = 100
    private static let rounds = 20

    /// A bound on failure, not a performance budget. A healthy round never comes near it, so
    /// making it generous costs a passing run nothing and keeps the suite honest under a
    /// sanitizer, where everything is an order of magnitude slower.
    private static let timeout: Double = 300

    /// Cancelling queued waiters must not lose any of them. `AsyncLock` is cancellation
    /// transparent, so every one of them still takes its turn and finishes.
    @Test
    func asyncLockLosesNoWaiterUnderConcurrentCancellation() async throws {
        for _ in 0..<Self.rounds {
            let lock = AsyncLock()
            let finished = AsyncSignal()
            let counter = CompletionCounter(target: Self.waiters, finished: finished)

            // Held so that everyone queues rather than sailing straight through.
            await lock.lock()

            let tasks = (0..<Self.waiters).map { _ in
                Task {
                    await lock.lock()
                    lock.unlock()
                    await counter.increment()
                }
            }

            try await lock.waitForPendingOperations(Self.waiters, timeout: Self.timeout)

            for index in stride(from: 0, to: Self.waiters, by: 3) {
                tasks[index].cancel()
            }

            lock.unlock()

            try await withTaskTimeout(seconds: Self.timeout) {
                try await finished.wait()
            }

            #expect(await counter.count == Self.waiters)

            // Catches the other shape of leak: a continuation that does resume while its
            // operation stays queued forever. That one never hangs, it just leaves the
            // primitive permanently convinced it is busy, so no timeout would notice.
            #expect(lock.pendingCount == .zero)
        }
    }

    /// Same contract on the semaphore, with several permits in play so waiters are woken in
    /// overlapping batches rather than one at a time.
    @Test
    func asyncSemaphoreLosesNoWaiterUnderConcurrentCancellation() async throws {
        for _ in 0..<Self.rounds {
            let permits = 4
            let semaphore = AsyncSemaphore(permits: permits)
            let finished = AsyncSignal()
            let counter = CompletionCounter(target: Self.waiters, finished: finished)

            for _ in 0..<permits {
                await semaphore.wait()
            }

            let tasks = (0..<Self.waiters).map { _ in
                Task {
                    await semaphore.withPermitVoid {}
                    await counter.increment()
                }
            }

            try await semaphore.waitForWaiters(Self.waiters, timeout: Self.timeout)

            for index in stride(from: 0, to: Self.waiters, by: 3) {
                tasks[index].cancel()
            }

            for _ in 0..<permits {
                semaphore.signal()
            }

            try await withTaskTimeout(seconds: Self.timeout) {
                try await finished.wait()
            }

            #expect(await counter.count == Self.waiters)
            #expect(semaphore.waitingCount == .zero)

            // Every permit taken came back exactly once: none lost, none duplicated.
            #expect(semaphore.availablePermits == permits)
        }
    }

    /// The original defect, at scale. A waiter cancelled while queued used to have its
    /// continuation thrown away, so its task never returned and never reported anything.
    ///
    /// Cancelling half of them while the other half is released by the signal puts both
    /// endings in flight at once, which is the interleaving that used to lose one.
    @Test
    func asyncSignalLosesNoWaiterWhenHalfAreCancelled() async throws {
        for _ in 0..<Self.rounds {
            let signal = AsyncSignal()
            let finished = AsyncSignal()
            let counter = CompletionCounter(target: Self.waiters, finished: finished)

            let tasks = (0..<Self.waiters).map { _ in
                Task {
                    // Both outcomes are fine. What is not fine is neither of them arriving.
                    _ = try? await signal.wait()
                    await counter.increment()
                }
            }

            // Everyone queued before anything is cancelled, so every round actually exercises
            // the window instead of racing tasks that have not reached the signal yet.
            try await signal.waitForWaiters(Self.waiters, timeout: Self.timeout)

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for index in stride(from: 0, to: Self.waiters, by: 2) {
                        tasks[index].cancel()
                    }
                }

                group.addTask {
                    signal.signal()
                }
            }

            try await withTaskTimeout(seconds: Self.timeout) {
                try await finished.wait()
            }

            #expect(await counter.count == Self.waiters)
            #expect(signal.waitingCount == .zero)
        }
    }

    /// Cancelling every waiter is a different path, not just a stricter version of the one
    /// above: each cancellation removes itself from the queue, so the signal arrives to find
    /// nothing left to release. A hundred removals in a row followed by an empty drain is
    /// where an off by one in the queue would show.
    @Test
    func asyncSignalLosesNoWaiterWhenAllAreCancelled() async throws {
        for _ in 0..<Self.rounds {
            let signal = AsyncSignal()
            let finished = AsyncSignal()
            let counter = CompletionCounter(target: Self.waiters, finished: finished)

            let tasks = (0..<Self.waiters).map { _ in
                Task {
                    _ = try? await signal.wait()
                    await counter.increment()
                }
            }

            try await signal.waitForWaiters(Self.waiters, timeout: Self.timeout)

            for task in tasks {
                task.cancel()
            }

            signal.signal()

            try await withTaskTimeout(seconds: Self.timeout) {
                try await finished.wait()
            }

            #expect(await counter.count == Self.waiters)
            #expect(signal.waitingCount == .zero)
        }
    }

    /// Subjects sit on top of `AsyncSignal`, so the same defect reached every `for await` in
    /// the package. Cancelling a subscriber has to end its loop, not park it.
    @Test
    func subjectSubscribersAllTerminateWhenCancelled() async throws {
        for _ in 0..<Self.rounds {
            let subject = EventSubject<Int>()
            let finished = AsyncSignal()
            let counter = CompletionCounter(target: Self.waiters, finished: finished)

            // Attached here, synchronously, before a single task exists. `makeAsyncIterator()`
            // is what fixes a subscriber's position in the chain, so creating them up front
            // removes the gap between "a task was created" and "that task reached its loop".
            // The previous version slept for fifty milliseconds and hoped, which under a
            // sanitizer is not a safe bet, and a subject has no waiter count to poll instead.
            let iterators = (0..<Self.waiters).map { _ in subject.makeAsyncIterator() }

            let tasks = iterators.map { iterator in
                Task {
                    var iterator = iterator

                    while await iterator.next() != nil {}

                    await counter.increment()
                }
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for task in tasks {
                        task.cancel()
                    }
                }

                group.addTask {
                    subject.completed()
                }
            }

            try await withTaskTimeout(seconds: Self.timeout) {
                try await finished.wait()
            }

            #expect(await counter.count == Self.waiters)
        }
    }
}

/// The watchdog runs on a detached utility task, so it fires whenever the executor gets to it.
/// What matters is not that it is prompt, but that being late never makes it wrong.
struct AsyncLockWatchdogTests {

    /// A bound on failure, not a performance budget, same as in the stress suite above. A
    /// healthy run never comes near it.
    private static let timeout: Double = 300

    /// A watchdog that wakes long after its section ended must stay quiet, including when a
    /// different acquisition holds the lock by then. That second case is why the check is
    /// against the holding operation's identity and not against "is the lock held".
    @Test
    func staysSilentForSectionsReleasedInTime() async throws {
        let deadline: Double = 2
        let reports = InlineProperty(wrappedValue: [String]())

        let lock = AsyncLock(
            watchdog: .init(seconds: deadline) { report in
                reports.withValue { $0.append(report) }
            }
        )

        // Two hundred short sections means two hundred watchdog tasks in flight, each waking
        // to find either a free lock or one held by a later acquisition.
        for _ in 0..<200 {
            await lock.withLockVoid {}
        }

        // Past the deadline of the last one, so every scheduled watchdog has had its turn.
        // A slower machine only gives them more time to misfire, which makes this stricter
        // rather than flakier.
        try await Task.sleep(nanoseconds: UInt64((deadline + 1) * 1_000_000_000))

        #expect(reports.wrappedValue.isEmpty)
    }

    /// Contention does not turn into noise: a waiter queued behind a long section is not the
    /// holder, so it is not what gets reported.
    @Test
    func reportsOnlyTheHolderWhileOthersAreQueued() async throws {
        let reported = AsyncSignal()
        let reports = InlineProperty(wrappedValue: [String]())

        let lock = AsyncLock(
            watchdog: .init(seconds: 0.1) { report in
                reports.withValue { $0.append(report) }
                reported.signal()
            }
        )

        await lock.lock()

        let waiters = (0..<20).map { _ in
            Task {
                await lock.lock()
                lock.unlock()
            }
        }

        try await lock.waitForPendingOperations(20, timeout: Self.timeout)

        try await withTaskTimeout(seconds: Self.timeout) {
            try await reported.wait()
        }

        // One holder, one report, however many are queued behind it.
        #expect(reports.wrappedValue.count == 1)

        lock.unlock()

        for waiter in waiters {
            await waiter.value
        }
    }
}
