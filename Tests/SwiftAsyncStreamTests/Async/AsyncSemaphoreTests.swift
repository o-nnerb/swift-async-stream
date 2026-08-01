// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@_spi(Testing) @testable import SwiftAsyncStream

/// Tracks how many tasks are inside a section at the same time.
///
/// Actor isolated on purpose. Counting through a shared box makes `active += 1` a read, a
/// modify and a write, so concurrent callers lose updates. A lost decrement leaves the counter
/// above the real occupancy, the peak drifts upward from there, and the test reports a
/// violation the semaphore never committed.
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

struct AsyncSemaphoreTests {

    /// Holds every admitted task inside the section until the test says otherwise, instead of
    /// giving each one a fixed sleep and hoping the overlap happens.
    ///
    /// The sleeping version passed everywhere but took ten seconds on tvOS, which is the shape
    /// of a test that is one bad scheduling day away from flaking. Here nothing is timed: the
    /// permits are all taken, the test confirms that the rest are queued, and only then are
    /// they released.
    @Test
    func limitsConcurrencyToTheNumberOfPermits() async throws {
        let permits = 3
        let total = 30

        let semaphore = AsyncSemaphore(permits: permits)
        let probe = ConcurrencyProbe()
        let release = AsyncSignal()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await semaphore.withPermitVoid {
                        await probe.begin()
                        try? await release.wait()
                        await probe.end()
                    }
                }
            }

            // Every permit taken, and everyone else queued behind them. Waiting for this shape
            // is what guarantees the overlap the assertion is about.
            try? await semaphore.waitForWaiters(total - permits, timeout: 300)

            release.signal()
        }

        #expect(await probe.peak == permits)
    }

    @Test
    func withPermitReturnsTheClosureValue() async {
        let semaphore = AsyncSemaphore(permits: 1)

        let result = await semaphore.withPermit { 42 }

        #expect(result == 42)
        #expect(semaphore.availablePermits == 1)
    }

    @Test
    func releasesThePermitWhenTheClosureThrows() async throws {
        let semaphore = AsyncSemaphore(permits: 1)

        struct TestError: Error {}

        await #expect(throws: TestError.self) {
            try await semaphore.withPermit {
                throw TestError()
            }
        }

        // The permit came back despite the throw, so acquiring again does not hang.
        try await withTaskTimeout(seconds: 300) {
            await semaphore.withPermitVoid {}
        }
    }

    @Test
    func handsThePermitStraightToTheNextWaiterInFIFOOrder() async throws {
        let semaphore = AsyncSemaphore(permits: 1)
        let order = InlineProperty(wrappedValue: [Int]())

        await semaphore.wait()

        // Admitted one at a time. Task creation order is not task arrival order, so the
        // expected order is only well defined if each waiter is confirmed before the next
        // one is created.
        let tasks = InlineProperty(wrappedValue: [Task<Void, Never>]())

        for index in 0..<5 {
            tasks.wrappedValue.append(
                Task {
                    await semaphore.withPermitVoid {
                        // Serialized by the single permit, so a shared box is safe here.
                        order.wrappedValue.append(index)
                    }
                }
            )

            try await semaphore.waitForWaiters(index + 1)
        }

        semaphore.signal()

        try await withTaskTimeout(seconds: 300) {
            for task in tasks.wrappedValue {
                await task.value
            }
        }

        #expect(order.wrappedValue == Array(0..<5))
    }

    // MARK: - Cancellation

    /// Like `AsyncLock`, waiting is cancellation transparent: the release guarantee comes from
    /// `defer` inside `withPermit`, so a cancelled waiter still takes its turn.
    @Test
    func cancelledWaiterStillTakesItsTurn() async throws {
        let semaphore = AsyncSemaphore(permits: 1)
        let acquired = AsyncSignal()

        await semaphore.wait()

        let task = Task {
            await semaphore.withPermitVoid {
                acquired.signal()
            }
        }

        try await semaphore.waitForWaiters(1)
        task.cancel()

        // Still queued, because cancelling does not remove a waiter. Asserted through the
        // queue rather than by waiting a while and hoping nothing happened.
        #expect(semaphore.waitingCount == 1)

        semaphore.signal()

        try await withTaskTimeout(seconds: 300) {
            try await acquired.wait()
        }

        await task.value
    }

    // MARK: - Debugging

    @available(iOS 16, tvOS 16, watchOS 9, macOS 13, *)
    @Test
    func debugDescriptionReportsAvailableAndWaitingCounts() async throws {
        let semaphore = AsyncSemaphore(permits: 2)

        await semaphore.wait()
        await semaphore.wait()

        let task = Task { await semaphore.wait() }
        try await semaphore.waitForWaiters(1)

        #expect(semaphore.debugDescription.contains("available: 0"))
        #expect(semaphore.debugDescription.contains("waiting (1)"))

        semaphore.signal()
        try await withTaskTimeout(seconds: 300) { await task.value }
        semaphore.signal()
    }
}
