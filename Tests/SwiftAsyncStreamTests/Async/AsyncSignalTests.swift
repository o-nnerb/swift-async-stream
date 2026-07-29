// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import SwiftAsyncStream

struct AsyncSignalTests {

    @Test
    func basicSignal() async throws {
        let signal = AsyncSignal()

        let task = Task {
            try await signal.wait()
        }

        // Allow time for wait to start
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

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

        // Wait a bit to ensure the task has started waiting
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        #expect(!completed.wrappedValue) // Should not be completed yet

        signal.signal()
        try await task.value
        #expect(completed.wrappedValue) // Should now be completed
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

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
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

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
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

    /// A signal already open when the waiter cancels resolves the race in favour of whichever
    /// side wins first, but never hangs regardless of the outcome.
    @Test
    func signalAndCancelRaceNeverHangs() async throws {
        for _ in 0..<200 {
            let signal = AsyncSignal()

            let task = Task {
                try await signal.wait()
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { task.cancel() }
                group.addTask { signal.signal() }
            }

            try await withTaskTimeout(seconds: 1) {
                _ = try? await task.value
            }
        }
    }
}
