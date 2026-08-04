// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import SwiftAsyncTesting
import Testing

struct AsyncExpectationTests {

    @Test
    func fulfillingAllExpectationsResolvesTheWait() async throws {
        let first = AsyncExpectation()
        let second = AsyncExpectation()

        Task {
            first.fulfill()
            second.fulfill()
        }

        try await expectations([first, second], timeout: 1)
    }

    @Test
    func aNeverFulfilledExpectationThrowsATimeoutNamingItself() async throws {
        let expectation = AsyncExpectation(description: "arrives-late")

        await #expect(throws: AsyncExpectationTimeout.self) {
            try await expectations([expectation], timeout: 0.2)
        }
    }

    /// The bug this guards against: `fulfill()` read, incremented and compared the counter as
    /// three separate locked operations, so concurrent callers could lose an increment and the
    /// expectation would wait for a count it could no longer reach.
    @Test
    func expectedFulfillmentCountIsAtomicUnderConcurrentFulfillment() async throws {
        let expectation = AsyncExpectation()
        expectation.expectedFulfillmentCount = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    expectation.fulfill()
                }
            }
        }

        try await expectations([expectation], timeout: 1)
    }

    @Test
    func overFulfillingRecordsAnIssue() async {
        let expectation = AsyncExpectation()

        withKnownIssue {
            expectation.fulfill()
            expectation.fulfill()
        }
    }

    @Test
    func overFulfillingCanBeOptedOut() async throws {
        let expectation = AsyncExpectation()
        expectation.assertForOverFulfill = false

        expectation.fulfill()
        expectation.fulfill()

        try await expectations([expectation], timeout: 1)
    }

    // MARK: - Inverted expectations

    /// The bug this guards against: fulfilling an inverted expectation only recorded the
    /// failure, it never released the wait, so the suite paid the full timeout even though
    /// the outcome was already known.
    ///
    /// Racing this against a `withTaskTimeout` deadline would repeat the exact mistake
    /// `TaskTimeoutTests` warns about: a tight deadline over a body that finishes on its own
    /// is a race against the scheduler, and `expectations` already nests its own
    /// `withTaskTimeout` per expectation, adding scheduling overhead on top. Measuring the
    /// elapsed time instead avoids piling on more competing tasks, and a generous bound is
    /// enough to tell "resolved via the signal" apart from "resolved via the 60 second
    /// timeout" without being sensitive to scheduler noise.
    @Test
    func fulfillingAnInvertedExpectationFailsAndReturnsImmediately() async throws {
        let expectation = AsyncExpectation()
        expectation.isInverted = true

        withKnownIssue {
            expectation.fulfill()
        }

        let elapsed = try await ContinuousClock().measure {
            try await expectations([expectation], timeout: 60)
        }

        #expect(elapsed < .seconds(30))
    }

    @Test
    func anInvertedExpectationThatIsNeverFulfilledPassesAfterItsTimeout() async throws {
        let expectation = AsyncExpectation()
        expectation.isInverted = true

        try await expectations([expectation], timeout: 0.2)
    }
}
