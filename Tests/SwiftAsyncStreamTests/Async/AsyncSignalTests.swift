// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@_spi(Testing) @testable import SwiftAsyncStream

struct AsyncSignalTests {

    @Test
    func basicSignal() async throws {
        let signal = AsyncSignal()
        let waiting = AsyncSignal()

        let task = Task {
            waiting.signal()
            try await signal.wait()
        }

        try await waiting.wait()
        signal.signal()

        try await task.value
    }

    @Test
    func multipleWaitsAfterSignal() async throws {
        let signal = AsyncSignal()

        // Signal first
        signal.signal()

        // Multiple awaits should all return immediately
        try await signal.wait()
        try await signal.wait()
        try await signal.wait()
    }

    @Test
    func waitsUntilSignaled() async throws {
        let signal = AsyncSignal()
        let completed = InlineProperty(wrappedValue: false)

        let task = Task {
            try await signal.wait()
            completed.wrappedValue = true
        }

        // Waits for the task to actually be queued, rather than sleeping and assuming it got
        // there. Nothing can have completed while a waiter is still pending.
        try await signal.waitForWaiters(1, timeout: 300)
        #expect(!completed.wrappedValue)

        signal.signal()
        try await task.value
        #expect(completed.wrappedValue)
    }

    @Test
    func lockClosesTheSignalAgain() async throws {
        let signal = AsyncSignal(true)

        // Starts open.
        try await signal.wait()

        signal.lock()

        let completed = InlineProperty(wrappedValue: false)
        let task = Task {
            try await signal.wait()
            completed.wrappedValue = true
        }

        try await signal.waitForWaiters(1, timeout: 300)
        #expect(!completed.wrappedValue)

        signal.signal()
        try await task.value
        #expect(completed.wrappedValue)
    }

    // MARK: - Cancellation

    /// Unlike `AsyncLock`, nothing guarantees `signal()` is ever called, so waiting has to be
    /// cancellable. A cancelled waiter throws instead of suspending forever.
    @Test
    func cancellingTheWaitingTaskThrows() async throws {
        let signal = AsyncSignal()

        let task = Task {
            try await signal.wait()
        }

        try await signal.waitForWaiters(1, timeout: 300)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    /// A task cancelled before it ever reaches the wait still observes the cancellation,
    /// instead of the continuation being dropped and the task suspending forever.
    @Test
    func cancellingBeforeWaitingStillThrows() async throws {
        let signal = AsyncSignal()

        let task = Task {
            try Task.checkCancellation()
            try await signal.wait()
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    /// Signalling and cancelling reach the same waiter from two sides. Whichever wins, the task
    /// has to end: the failure this guards against is a continuation nobody resumes.
    ///
    /// Waiting for the waiter to actually be queued before racing signal against cancel is what
    /// makes every round exercise the window, rather than most of them racing a task that had
    /// not reached the signal yet.
    @Test
    func signalAndCancelRaceNeverHangs() async throws {
        for _ in 0..<50 {
            let signal = AsyncSignal()

            let task = Task {
                try await signal.wait()
            }

            try await signal.waitForWaiters(1, timeout: 300)

            await withTaskGroup(of: Void.self) { group in
                group.addTask { task.cancel() }
                group.addTask { signal.signal() }
            }

            try await withTaskTimeout(seconds: 300) {
                _ = try? await task.value
            }
        }
    }

}
