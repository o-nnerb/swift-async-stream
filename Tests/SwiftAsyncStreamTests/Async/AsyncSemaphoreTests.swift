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

    @Test
    func limitsConcurrencyToTheNumberOfPermits() async {
        let semaphore = AsyncSemaphore(permits: 3)
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    await semaphore.withPermitVoid {
                        await probe.begin()
                        try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
                        await probe.end()
                    }
                }
            }
        }

        #expect(await probe.peak == 3)
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
        try await withTaskTimeout(seconds: 1) {
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

        try await withTaskTimeout(seconds: 2) {
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
        let acquired = InlineProperty(wrappedValue: false)

        await semaphore.wait()

        let task = Task {
            await semaphore.withPermitVoid {
                acquired.wrappedValue = true
            }
        }

        try await semaphore.waitForWaiters(1)
        task.cancel()

        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        #expect(!acquired.wrappedValue)

        semaphore.signal()

        try await withTaskTimeout(seconds: 1) {
            await task.value
        }

        #expect(acquired.wrappedValue)
    }

    // MARK: - Debugging

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
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
        try await withTaskTimeout(seconds: 1) { await task.value }
        semaphore.signal()
    }
}
