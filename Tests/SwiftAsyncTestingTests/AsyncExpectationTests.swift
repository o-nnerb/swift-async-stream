import Testing
import SwiftAsyncTesting

struct AsyncExpectationTests {

    @Test("AsyncExpectation fulfills and waits properly")
    func testBasicFulfillment() async throws {
        let expectation = AsyncExpectation(description: "Test expectation")

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
            expectation.fulfill()
        }

        try await expectations([expectation], timeout: 5.0)
    }

    @Test("AsyncExpectation with multiple fulfillments")
    func testMultipleFulfillments() async throws {
        let expectation = AsyncExpectation(description: "Multiple fulfillment test")
        expectation.expectedFulfillmentCount = 3

        Task {
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 25_000_000) // 25ms delay between fulfillments
                expectation.fulfill()
            }
        }

        try await expectations([expectation], timeout: 5.0)
    }

    @Test("AsyncExpectation timeout handling")
    func testTimeout() async {
        let expectation = AsyncExpectation(description: "Timeout test")

        // Don't fulfill the expectation - this should cause a timeout
        await #expect(throws: CancellationError.self) {
            try await expectations([expectation], timeout: 0.1) // Very short timeout
        }
    }

    @Test("Multiple expectations wait for all")
    func testMultipleExpectations() async throws {
        let expectation1 = AsyncExpectation(description: "First expectation")
        let expectation2 = AsyncExpectation(description: "Second expectation")

        Task {
            try? await Task.sleep(nanoseconds: 25_000_000)
            expectation1.fulfill()
        }

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            expectation2.fulfill()
        }

        try await expectations([expectation1, expectation2], timeout: 5.0)
    }

    @Test("Inverted expectation fails when fulfilled")
    func testInvertedExpectation() async {
        await withKnownIssue {
            let expectation = AsyncExpectation(description: "Inverted test")
            expectation.isInverted = true

            Task {
                try? await Task.sleep(nanoseconds: 25_000_000)
                expectation.fulfill() // This should cause a test failure
            }

            // We expect this to record an issue since the inverted expectation was fulfilled
            try? await expectations([expectation], timeout: 1.0)
        } matching: { issue in
            issue.comments.contains("Inverted expectation was fulfilled, which is a failure.")
        }
    }

    @Test("AsyncExpectation handles over-fulfillment")
    func testOverFulfillment() async throws {
        try await withKnownIssue {
            let assertionTracker = AsyncExpectation()
            let expectation = AsyncExpectation(description: "Over-fulfillment test")
            expectation.expectedFulfillmentCount = 1
            expectation.assertForOverFulfill = true

            Task {
                try? await Task.sleep(nanoseconds: 25_000_000)
                expectation.fulfill() // First fulfillment
                expectation.fulfill() // This should trigger an assertion
                assertionTracker.fulfill()
            }

            try await expectations([expectation, assertionTracker], timeout: 5.0)
        } matching: { issue in
            issue.comments.contains("Expected fulfill count to be 1, got 2.")
        }
    }

    @Test("AsyncExpectation works with Task timeout")
    func testTaskTimeout() async throws {
        let expectation = AsyncExpectation(description: "Task timeout test")

        Task {
            // Simulate an async operation that completes within timeout
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            expectation.fulfill()
        }

        try await expectations([expectation], timeout: 2.0)
    }
}

