// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import SwiftAsyncStream

struct TaskTimeoutTests {

    @Test
    func returnsTheValueWhenTheOperationFinishesInTime() async throws {
        let value = try await withTaskTimeout(seconds: 1) {
            42
        }

        #expect(value == 42)
    }

    @Test
    func throwsATaskTimeoutErrorWhenTheDeadlinePasses() async throws {
        await #expect(throws: TaskTimeoutError.self) {
            try await withTaskTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s, past the deadline
            }
        }
    }

    @Test
    func propagatesTheOperationsError() async throws {
        struct TestError: Error {}

        await #expect(throws: TestError.self) {
            try await withTaskTimeout(seconds: 1) {
                throw TestError()
            }
        }
    }

    /// Structured, not orphaned: cancelling the caller cancels the operation instead of
    /// leaving it running unstructured in the background.
    @Test
    func cancellingTheCallerCancelsTheOperation() async throws {
        let started = AsyncSignal()
        let cancelled = InlineProperty(wrappedValue: false)

        let task = Task {
            try await withTaskTimeout(seconds: 5) {
                started.signal()
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                } catch {
                    cancelled.wrappedValue = true
                    throw error
                }
            }
        }

        try await started.wait()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        #expect(cancelled.wrappedValue)
    }

    /// Whichever side of the race loses is cancelled. Here the deadline wins, so the operation
    /// has to be the one cancelled, not left running past the timeout.
    @Test
    func losingTheTimeoutCancelsTheOperationInstead() async throws {
        let cancelled = InlineProperty(wrappedValue: false)

        await #expect(throws: TaskTimeoutError.self) {
            try await withTaskTimeout(seconds: 0.05) {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                } catch {
                    cancelled.wrappedValue = true
                    throw error
                }
            }
        }

        #expect(cancelled.wrappedValue)
    }
}
