// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// An error thrown when a test helper times out waiting for a queue to reach a known shape.
///
/// This usually indicates a race condition or a deadlock in tests where tasks are not being
/// enqueued as expected.
@_spi(Testing)
public struct PendingWaitersTimeout: Error, CustomStringConvertible {

    /// The number of pending waiters the test expected to find.
    public let expected: Int

    /// The actual number of pending waiters found when the timeout occurred.
    public let found: Int

    public var description: String {
        "Timed out waiting for \(expected) pending waiters, found \(found)"
    }

    /// Creates a new timeout error.
    /// - Parameters:
    ///   - expected: The expected number of pending waiters.
    ///   - found: The actual number of pending waiters found.
    init(expected: Int, found: Int) {
        self.expected = expected
        self.found = found
    }
}

// MARK: - Polling

/// Polls until `value()` matches `count`.
///
/// Creating a `Task` does not decide when it reaches a queue, so a test that needs a known
/// queue order has to wait for each waiter to arrive instead of assuming that creation order
/// is arrival order.
///
/// Counts iterations rather than reading a clock, so it works below the deployment target of
/// `ContinuousClock` and keeps the package free of Foundation.
///
/// The `isolation` parameter lets `value` read actor isolated state when the caller is an
/// actor, and costs nothing when it is not.
func waitForCount(
    _ count: Int,
    timeout: Double,
    isolation: isolated (any Actor)? = #isolation,
    value: () -> Int
) async throws {
    let attempts = max(1, Int(timeout * 1000))

    for _ in 0..<attempts {
        if value() == count {
            return
        }

        try await Task.sleep(nanoseconds: 1_000_000)  // 1ms
    }

    throw PendingWaitersTimeout(expected: count, found: value())
}
