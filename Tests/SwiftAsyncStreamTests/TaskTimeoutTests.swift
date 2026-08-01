// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SwiftAsyncStream

struct TaskTimeoutTests {

    /// A deadline in a test is one of two things, and never anything in between.
    ///
    /// Either it is the thing under test, in which case the body has to be **incapable** of
    /// finishing, so the deadline is the only possible outcome. Or it is incidental, in which
    /// case it has to be far out of the executor's reach, so scheduling can never beat it.
    ///
    /// Anything in the middle is a race against the scheduler. A one second deadline over a
    /// body that throws instantly reads as an enormous margin, and a watchOS simulator running
    /// twenty times slow spent twenty four seconds before the body was ever scheduled: the
    /// deadline fired, correctly, and the test failed for it.
    private static let unreachableDeadline: Double = 300

    @Test
    func returnsTheValueWhenTheOperationFinishesInTime() async throws {
        let value = try await withTaskTimeout(seconds: Self.unreachableDeadline) {
            42
        }

        #expect(value == 42)
    }

    /// The body can never finish, so the deadline is the only way out.
    ///
    /// This used to race a fifty millisecond deadline against a one second sleep, which reads
    /// as a comfortable margin and is not one: `addTask` creates a child, it does not run one,
    /// and on a starved executor the group hands back whichever child happened to complete.
    /// tvOS took eight seconds over this test and reported that nothing was thrown.
    @Test
    func throwsATaskTimeoutErrorWhenTheDeadlinePasses() async throws {
        let neverSignalled = AsyncSignal()

        await #expect(throws: TaskTimeoutError.self) {
            try await withTaskTimeout(seconds: 0.05) {
                try await neverSignalled.wait()
            }
        }
    }

    @Test
    func propagatesTheOperationsError() async throws {
        struct TestError: Error {}

        await #expect(throws: TestError.self) {
            try await withTaskTimeout(seconds: Self.unreachableDeadline) {
                throw TestError()
            }
        }
    }

    /// Structured, not orphaned: cancelling the caller cancels the operation instead of
    /// leaving it running unstructured in the background.
    @Test
    func cancellingTheCallerCancelsTheOperation() async throws {
        let started = AsyncSignal()
        let neverSignalled = AsyncSignal()
        let cancelled = InlineProperty(wrappedValue: false)

        let task = Task {
            try await withTaskTimeout(seconds: Self.unreachableDeadline) {
                started.signal()

                do {
                    try await neverSignalled.wait()
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
    /// has to be the one cancelled rather than left running past the timeout.
    @Test
    func losingTheTimeoutCancelsTheOperationInstead() async throws {
        let neverSignalled = AsyncSignal()
        let cancelled = AsyncSignal()

        await #expect(throws: TaskTimeoutError.self) {
            try await withTaskTimeout(seconds: 0.05) {
                do {
                    try await neverSignalled.wait()
                } catch {
                    cancelled.signal()
                    throw error
                }
            }
        }

        // Waited for rather than asserted straight away. `withTaskTimeout` returns as soon as
        // the deadline wins, and the losing child is cancelled and drained on the way out of
        // the group, which is ordered after that but not instantaneous.
        try await withTaskTimeout(seconds: Self.unreachableDeadline) {
            try await cancelled.wait()
        }
    }
}
