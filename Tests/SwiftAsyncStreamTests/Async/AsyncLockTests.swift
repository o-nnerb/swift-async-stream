// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@_spi(Testing) @testable import SwiftAsyncStream

struct AsyncLockTests {

    @Test
    func basicLock() async throws {
        let asyncLock = AsyncLock()

        let counter = InlineProperty(wrappedValue: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await asyncLock.withLock {
                        let current = counter.wrappedValue
                        try? await Task.sleep(nanoseconds: 1000)
                        counter.wrappedValue = current + 1
                    }
                }
            }
        }

        #expect(counter.wrappedValue == 100)
    }

    @Test
    func lockWithReturnValue() async throws {
        let asyncLock = AsyncLock()
        let value = InlineProperty(wrappedValue: 0)

        let result = await asyncLock.withLock {
            value.wrappedValue = 42
            return value.wrappedValue * 2
        }

        #expect(result == 84)
        #expect(value.wrappedValue == 42)
    }

    @Test
    func voidLock() async throws {
        let asyncLock = AsyncLock()
        let called = InlineProperty(wrappedValue: false)

        await asyncLock.withLockVoid {
            called.wrappedValue = true
            try? await Task.sleep(nanoseconds: 1000)
        }

        #expect(called.wrappedValue == true)
    }

    @Test
    func exclusiveAccess() async throws {
        let asyncLock = AsyncLock()
        let sharedResource = InlineProperty(wrappedValue: 0)
        let accessOrder = InlineProperty(wrappedValue: [Int]())

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await asyncLock.withLock {
                        let taskId = i
                        sharedResource.wrappedValue = taskId
                        try? await Task.sleep(nanoseconds: 100_000)  // 100ms
                        #expect(sharedResource.wrappedValue == taskId)
                        accessOrder.wrappedValue.append(taskId)
                    }
                }
            }
        }

        #expect(accessOrder.wrappedValue.count == 10)
    }

    @Test
    func concurrentPerformance() async throws {
        let asyncLock = AsyncLock()
        let lock = Lock()
        let iterations = 1000
        let counter = InlineProperty(wrappedValue: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await asyncLock.withLock {
                        lock.withLock {
                            counter.wrappedValue += 1
                        }
                    }
                }
            }
        }

        #expect(counter.wrappedValue == iterations)
    }

    @Test
    func errorHandling() async throws {
        let asyncLock = AsyncLock()

        struct TestError: Error {}

        await #expect(throws: TestError.self) {
            try await asyncLock.withLock {
                throw TestError()
            }
        }

        let executed = InlineProperty(wrappedValue: false)
        await asyncLock.withLock {
            executed.wrappedValue = true
        }

        #expect(executed.wrappedValue == true)
    }

    @Test
    func manualLockUnlock() async throws {
        let asyncLock = AsyncLock()
        let counter = InlineProperty(wrappedValue: 0)

        await asyncLock.lock()
        counter.wrappedValue += 1
        asyncLock.unlock()

        await asyncLock.lock()
        counter.wrappedValue += 1
        asyncLock.unlock()

        #expect(counter.wrappedValue == 2)
    }

    // MARK: - Cancellation

    /// The lock is cancellation transparent: a task cancelled while waiting still takes its
    /// turn and runs, instead of being skipped or leaving the queue.
    @Test
    func cancelledWaiterStillTakesItsTurn() async throws {
        let lock = AsyncLock()
        let acquired = InlineProperty(wrappedValue: false)

        await lock.lock()

        let task = Task {
            await lock.lock()
            acquired.wrappedValue = true
            lock.unlock()
        }

        // Wait for the task to actually reach the queue before cancelling it.
        try await lock.waitForPendingOperations(1)
        task.cancel()

        // Cancelling a queued waiter does not remove it from the queue.
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        #expect(!acquired.wrappedValue)

        lock.unlock()

        try await withTaskTimeout(seconds: 1) {
            await task.value
        }

        #expect(acquired.wrappedValue)
    }

    /// Cancellation never reorders the queue. Every waiter is served FIFO regardless of which
    /// ones were cancelled while waiting.
    @Test
    func honorsFIFOOrderRegardlessOfCancellation() async throws {
        let lock = AsyncLock()
        let order = InlineProperty(wrappedValue: [Int]())

        await lock.lock()

        // Admitted one at a time. Creating a `Task` schedules it, it does not run it, so
        // creating all ten at once would let them race into the queue in whatever order the
        // cooperative pool happens to pick. Confirming each arrival is what makes the
        // expected order well defined.
        let tasks = InlineProperty(wrappedValue: [Task<Void, Never>]())

        for index in 0..<10 {
            tasks.wrappedValue.append(
                Task {
                    await lock.lock()
                    defer { lock.unlock() }
                    order.wrappedValue.append(index)
                }
            )

            try await lock.waitForPendingOperations(index + 1)
        }

        for index in stride(from: 1, to: 10, by: 2) {
            tasks.wrappedValue[index].cancel()
        }

        // Cancellation is transparent, so nobody leaves the queue.
        #expect(lock.pendingCount == 10)

        lock.unlock()

        try await withTaskTimeout(seconds: 2) {
            for task in tasks.wrappedValue {
                await task.value
            }
        }

        #expect(order.wrappedValue == Array(0..<10))
    }

    /// The lock is not reentrant. Acquiring it twice on the same task from the same instance
    /// deadlocks: the second acquisition queues behind the first, which cannot release until
    /// the second one returns.
    ///
    /// The deadlock is real and permanent, so it cannot be awaited to completion without
    /// hanging the test itself. Instead, this asserts the queue shape that proves the second
    /// acquisition is stuck waiting, and lets the task leak rather than joining it.
    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func lockIsNotReentrant() async throws {
        let asyncLock = AsyncLock()
        let counter = InlineProperty(wrappedValue: 0)

        let task = Task {
            await asyncLock.withLockVoid {
                counter.wrappedValue += 1

                // Deadlocks: this queues behind the outer acquisition on the same instance.
                await asyncLock.withLockVoid {
                    counter.wrappedValue += 1
                }

                counter.wrappedValue += 1
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        #expect(counter.wrappedValue == 1)
        #expect(asyncLock.debugDescription.contains("pending (1)"))

        // The task is permanently stuck and cannot be joined. Cancelling it does not free
        // the lock either, since cancellation is transparent here by design.
        task.cancel()
    }

    // MARK: - Watchdog

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func watchdogReportsASectionHeldPastItsDeadline() async throws {
        let reported = AsyncSignal()
        let report = InlineProperty<String?>(wrappedValue: nil)

        let lock = AsyncLock(
            watchdog: .init(seconds: 0.1) {
                report.wrappedValue = $0
                reported.signal()
            }
        )

        await lock.withLockVoid {
            // Waits for the watchdog instead of holding the lock for a fixed time and assuming
            // it will have fired. It runs on a detached utility task, which a loaded machine
            // will happily starve past any deadline the test picks: this failed on watchOS and
            // iPadOS with the whole test stretched to well over two seconds.
            //
            // The timeout is the failure mode, and it is generous on purpose. What is being
            // tested is that the watchdog reports at all while the section is held, not how
            // promptly a busy CI machine gets around to it.
            try? await withTaskTimeout(seconds: 300) {
                try await reported.wait()
            }
        }

        #expect(report.wrappedValue?.contains("AsyncLock held for more than") == true)
    }

    @Test
    func watchdogStaysSilentWithinTheDeadline() async throws {
        let report = InlineProperty<String?>(wrappedValue: nil)
        let lock = AsyncLock(watchdog: .init(seconds: 1) { report.wrappedValue = $0 })

        await lock.withLockVoid {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        try await Task.sleep(nanoseconds: 50_000_000)  // give a late report a chance to land
        #expect(report.wrappedValue == nil)
    }
}
