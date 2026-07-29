// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import SwiftAsyncStream

struct AsyncOperationTests {

    private static func makeOperation() -> AsyncOperation {
        AsyncOperation(debugInfo: .init(function: "test", file: "test", line: 0))
    }

    @Test
    func startsInTheWaitingState() {
        let operation = Self.makeOperation()
        #expect(operation.state == .waiting)
    }

    @Test
    func runTransitionsToRunningAndReturnsTheScheduledContinuation() async {
        let operation = Self.makeOperation()

        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            operation.schedule(continuation)
            #expect(operation.state == .waiting)

            let resumed = operation.run()

            #expect(resumed != nil)
            #expect(operation.state == .running)

            resumed?.resume()
        }
    }

    @Test
    func runIsIdempotentOnceRunning() async {
        let operation = Self.makeOperation()

        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            operation.schedule(continuation)

            let first = operation.run()
            let second = operation.run()

            #expect(first != nil)
            #expect(second == nil)

            first?.resume()
        }
    }

    @Test
    func cancelBeforeSchedulingMarksTheOperationCancelledWithoutAContinuationToResume() {
        let operation = Self.makeOperation()

        let resumed = operation.cancel()

        #expect(resumed == nil)
        #expect(operation.state == .cancelled)
    }

    /// The scenario behind the `AsyncSignal` fix: a task cancelled before it ever reaches
    /// `schedule` must not have its continuation silently dropped. `schedule` reports the
    /// miss so the caller resumes it itself.
    @Test
    func scheduleAfterCancelReportsThatItDidNotStoreTheContinuation() async {
        let operation = Self.makeOperation()
        _ = operation.cancel()

        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let didSchedule = operation.schedule(continuation)

            #expect(!didSchedule)
            continuation.resume()
        }
    }

    @Test
    func cancelAfterSchedulingReturnsTheContinuationToResume() async {
        let operation = Self.makeOperation()

        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            operation.schedule(continuation)

            let resumed = operation.cancel()

            #expect(resumed != nil)
            #expect(operation.state == .cancelled)

            resumed?.resume()
        }
    }

    /// The scenario behind the `AsyncLock` fix: an operation that already acquired must never
    /// be downgraded back to cancelled. It owns whatever contract came with running, and only
    /// it releases it.
    @Test
    func cancelNeverDowngradesARunningOperation() async {
        let operation = Self.makeOperation()

        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            operation.schedule(continuation)
            let running = operation.run()

            let resumed = operation.cancel()

            #expect(resumed == nil)
            #expect(operation.state == .running)

            running?.resume()
        }
    }

    @Test
    func cancelIsIdempotentOnceCancelled() {
        let operation = Self.makeOperation()

        _ = operation.cancel()
        let second = operation.cancel()

        #expect(second == nil)
        #expect(operation.state == .cancelled)
    }
}
