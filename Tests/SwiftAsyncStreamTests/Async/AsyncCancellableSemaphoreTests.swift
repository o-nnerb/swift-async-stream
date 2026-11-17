// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@_spi(Testing) @testable import SwiftAsyncStream

/// Tracks how many tasks are inside a section at the same time.
///
/// Actor isolated on purpose, for the same reason as in `AsyncSemaphoreTests`: counting through
/// a shared box loses updates and reports violations the semaphore never committed.
private actor ConcurrencyProbe {

    private(set) var peak = 0

    private var active = 0

    func begin() {
        active += 1
        peak = max(peak, active)
    }

    func end() {
        active -= 1
    }
}

struct AsyncCancellableSemaphoreTests {

    // MARK: - Admission

    @Test
    func limitsConcurrencyToTheNumberOfPermits() async throws {
        let permits = 3
        let total = 30

        let semaphore = AsyncCancellableSemaphore(permits: permits)
        let probe = ConcurrencyProbe()
        let release = AsyncSignal()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    try await semaphore.withPermitVoid {
                        await probe.begin()
                        try? await release.wait()
                        await probe.end()
                    }
                }
            }

            // Every permit taken, and everyone else queued behind them. Waiting for this shape
            // is what guarantees the overlap the assertion is about.
            try await semaphore.waitForWaiters(total - permits, timeout: 300)

            release.signal()

            try await group.waitForAll()
        }

        #expect(await probe.peak == permits)
        #expect(semaphore.availablePermits == permits)
        #expect(semaphore.waitingCount == 0)
    }

    @Test
    func withPermitReturnsTheClosureValue() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)

        let result = try await semaphore.withPermit { 42 }

        #expect(result == 42)
        #expect(semaphore.availablePermits == 1)
    }

    @Test
    func releasesThePermitWhenTheClosureThrows() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)

        struct TestError: Error {}

        await #expect(throws: TestError.self) {
            try await semaphore.withPermit {
                throw TestError()
            }
        }

        #expect(semaphore.availablePermits == 1)

        // The permit came back despite the throw, so acquiring again does not hang.
        try await withTaskTimeout(seconds: 300) {
            try await semaphore.withPermitVoid {}
        }
    }

    @Test
    func zeroPermitsIsAGateThatSignalOpens() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 0)

        let task = Task {
            try await semaphore.wait()
        }

        try await semaphore.waitForWaiters(1)
        semaphore.signal()

        try await withTaskTimeout(seconds: 300) {
            try await task.value
        }

        #expect(semaphore.availablePermits == 0)
    }

    // MARK: - Ordering

    @Test
    func servesWaitersInFIFOOrder() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)
        let order = InlineProperty(wrappedValue: [Int]())

        try await semaphore.wait()

        // Admitted one at a time. Task creation order is not task arrival order, so the
        // expected order is only well defined if each waiter is confirmed before the next one
        // is created.
        var tasks = [Task<Void, any Error>]()

        for index in 0..<5 {
            tasks.append(
                Task {
                    try await semaphore.withPermitVoid {
                        // Serialized by the single permit, so a shared box is safe here.
                        order.wrappedValue.append(index)
                    }
                }
            )

            try await semaphore.waitForWaiters(index + 1)
        }

        semaphore.signal()

        try await withTaskTimeout(seconds: 300) { [tasks] in
            for task in tasks {
                try await task.value
            }
        }

        #expect(order.wrappedValue == Array(0..<5))
    }

    @Test
    func handsThePermitStraightToTheFirstWaiter() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)

        try await semaphore.wait()

        let task = Task {
            try await semaphore.wait()
        }

        try await semaphore.waitForWaiters(1)

        semaphore.signal()

        // Handed over, not returned to the count. A permit that went back to the count first
        // could be taken by someone arriving in between, ahead of the one that waited.
        #expect(semaphore.availablePermits == 0)
        #expect(semaphore.waitingCount == 0)

        try await withTaskTimeout(seconds: 300) {
            try await task.value
        }

        semaphore.signal()
        #expect(semaphore.availablePermits == 1)
    }

    // MARK: - Cancellation

    @Test
    func cancelledWaiterLeavesTheQueueAndThrows() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)

        try await semaphore.wait()

        let task = Task {
            try await semaphore.wait()
        }

        try await semaphore.waitForWaiters(1)
        task.cancel()

        // Gone from the queue without anybody signalling, which is the whole difference with
        // a transparent semaphore.
        try await semaphore.waitForWaiters(0, timeout: 300)

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        // It never got a permit, so there is nothing for it to give back.
        #expect(semaphore.availablePermits == 0)

        semaphore.signal()
        #expect(semaphore.availablePermits == 1)
    }

    @Test
    func cancelledWaiterDoesNotRunItsClosure() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)
        let ran = InlineProperty(wrappedValue: false)

        try await semaphore.wait()

        let task = Task {
            try await semaphore.withPermitVoid {
                ran.wrappedValue = true
            }
        }

        try await semaphore.waitForWaiters(1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        #expect(!ran.wrappedValue)

        // And it did not return a permit it never held.
        semaphore.signal()
        #expect(semaphore.availablePermits == 1)
    }

    @Test
    func cancellingTheMiddleWaiterKeepsTheOthersInOrder() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)
        let order = InlineProperty(wrappedValue: [Int]())

        try await semaphore.wait()

        var tasks = [Task<Void, any Error>]()

        for index in 0..<3 {
            tasks.append(
                Task {
                    try await semaphore.withPermitVoid {
                        order.wrappedValue.append(index)
                    }
                }
            )

            try await semaphore.waitForWaiters(index + 1)
        }

        tasks[1].cancel()
        try await semaphore.waitForWaiters(2, timeout: 300)

        await #expect(throws: CancellationError.self) {
            try await tasks[1].value
        }

        // Unlinking the middle of the list must leave both neighbours reachable.
        semaphore.signal()

        try await withTaskTimeout(seconds: 300) { [tasks] in
            try await tasks[0].value
            try await tasks[2].value
        }

        #expect(order.wrappedValue == [0, 2])
        #expect(semaphore.availablePermits == 1)
        #expect(semaphore.waitingCount == 0)
    }

    @Test
    func cancellingTheFirstAndLastWaitersKeepsTheRestServed() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)
        let order = InlineProperty(wrappedValue: [Int]())

        try await semaphore.wait()

        var tasks = [Task<Void, any Error>]()

        for index in 0..<4 {
            tasks.append(
                Task {
                    try await semaphore.withPermitVoid {
                        order.wrappedValue.append(index)
                    }
                }
            )

            try await semaphore.waitForWaiters(index + 1)
        }

        // Head and tail, the two ends of the list, where the links to the queue itself change.
        tasks[0].cancel()
        tasks[3].cancel()
        try await semaphore.waitForWaiters(2, timeout: 300)

        semaphore.signal()

        try await withTaskTimeout(seconds: 300) { [tasks] in
            try await tasks[1].value
            try await tasks[2].value
        }

        #expect(order.wrappedValue == [1, 2])
        #expect(semaphore.availablePermits == 1)
    }

    @Test
    func taskCancelledBeforeAskingThrowsEvenWithAPermitAvailable() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)

        let task = Task {
            // Cancelled by the time it asks, because nothing is awaited before this loop ends.
            while !Task.isCancelled {
                await Task.yield()
            }

            try await semaphore.wait()
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        // No permit was taken, so there is nothing to return.
        #expect(semaphore.availablePermits == 1)
        #expect(semaphore.waitingCount == 0)
    }

    /// A permit already handed over belongs to its caller. Cancelling afterwards does not take
    /// it back, which is what keeps the pairing with `signal()` unambiguous.
    @Test
    func waiterGrantedBeforeCancellationKeepsItsPermit() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 1)

        try await semaphore.wait()

        let task = Task {
            try await semaphore.wait()
        }

        try await semaphore.waitForWaiters(1)

        semaphore.signal()
        task.cancel()

        try await withTaskTimeout(seconds: 300) {
            try await task.value
        }

        #expect(semaphore.availablePermits == 0)

        semaphore.signal()
        #expect(semaphore.availablePermits == 1)
    }

    /// Cancelling at the very moment a permit is returned must resolve one way or the other,
    /// without losing the permit or minting a second one.
    @Test
    func cancellationRacingWithSignalNeitherLosesNorDuplicatesAPermit() async throws {
        for _ in 0..<300 {
            let semaphore = AsyncCancellableSemaphore(permits: 1)

            try await semaphore.wait()

            let task = Task { () -> Bool in
                do {
                    try await semaphore.wait()
                    return true
                } catch {
                    return false
                }
            }

            try await semaphore.waitForWaiters(1)

            await withTaskGroup(of: Void.self) { group in
                group.addTask { task.cancel() }
                group.addTask { semaphore.signal() }
            }

            let acquired = try await withTaskTimeout(seconds: 300) {
                await task.value
            }

            if acquired {
                // Won the race, so the permit is its to give back.
                #expect(semaphore.availablePermits == 0)
                semaphore.signal()
            }

            #expect(semaphore.availablePermits == 1)
            #expect(semaphore.waitingCount == 0)
        }
    }

    @Test
    func manyWaitersWithSomeCancelledAllSettleAndRestoreEveryPermit() async throws {
        let permits = 3
        let total = 200

        let semaphore = AsyncCancellableSemaphore(permits: permits)
        let release = AsyncSignal()

        let tasks = (0..<total).map { _ in
            Task { () -> Bool in
                do {
                    try await semaphore.withPermitVoid {
                        try? await release.wait()
                    }

                    return true
                } catch {
                    return false
                }
            }
        }

        try await semaphore.waitForWaiters(total - permits, timeout: 300)

        for index in tasks.indices where index.isMultiple(of: 3) {
            tasks[index].cancel()
        }

        release.signal()

        let outcomes = try await withTaskTimeout(seconds: 300) {
            var outcomes = [Bool]()

            for task in tasks {
                outcomes.append(await task.value)
            }

            return outcomes
        }

        // A task nobody cancelled always gets its turn.
        for index in tasks.indices where !index.isMultiple(of: 3) {
            #expect(outcomes[index])
        }

        #expect(semaphore.availablePermits == permits)
        #expect(semaphore.waitingCount == 0)
    }

    // MARK: - Debugging

    @available(iOS 16, tvOS 16, watchOS 9, macOS 13, *)
    @Test
    func debugDescriptionReportsAvailableAndWaitingCounts() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 2)

        try await semaphore.wait()
        try await semaphore.wait()

        let task = Task { try await semaphore.wait() }
        try await semaphore.waitForWaiters(1)

        #expect(semaphore.debugDescription.contains("available: 0"))
        #expect(semaphore.debugDescription.contains("waiting (1)"))

        semaphore.signal()
        try await withTaskTimeout(seconds: 300) { try await task.value }
        semaphore.signal()
        semaphore.signal()
    }
}
