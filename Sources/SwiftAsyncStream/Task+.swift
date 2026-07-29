// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

// MARK: - TaskTimeoutError

/// An error thrown when an operation wrapped by `withTaskTimeout` exceeds its deadline.
///
/// Distinct from `CancellationError` on purpose: a caller needs to tell "the work took too
/// long" apart from "I was cancelled", because only the first one is a candidate for a retry.
public struct TaskTimeoutError: Error, CustomStringConvertible, Sendable {

    /// The timeout that was exceeded, in seconds.
    public let seconds: Double

    public var description: String {
        "Timed out after \(seconds) seconds"
    }

    init(seconds: Double) {
        self.seconds = seconds
    }
}

// MARK: - withTaskTimeout

/// Executes an asynchronous operation with a timeout.
/// If the operation doesn't complete within the specified time, it will be cancelled.
///
/// The operation and the deadline run as children of the current task, so cancelling the
/// caller cancels both, and whichever finishes first cancels the other.
///
/// - Parameters:
///   - seconds: The timeout duration in seconds.
///   - valueType: The type of value to return (inferred automatically).
///   - body: The asynchronous operation to execute.
/// - Returns: The result of the operation if it completes within the timeout.
/// - Throws: `TaskTimeoutError` if the timeout is reached, `CancellationError` if the calling
/// task is cancelled, or any error thrown by the operation.
@discardableResult
public func withTaskTimeout<Value: Sendable>(
    seconds: Double,
    of valueType: Value.Type = Value.self,
    body: @Sendable @escaping () async throws -> Value
) async throws -> Value {
    precondition(seconds >= .zero, "withTaskTimeout requires a non negative timeout")

    let nanoseconds = nanoseconds(from: seconds)

    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await body()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw TaskTimeoutError(seconds: seconds)
        }

        // Whoever loses the race is cancelled, and its result is discarded when the group
        // drains on the way out.
        defer { group.cancelAll() }

        guard let value = try await group.next() else {
            throw CancellationError()
        }

        return value
    }
}

// MARK: - Private methods

private func nanoseconds(from seconds: Double) -> UInt64 {
    let nanoseconds = (seconds * 1_000_000_000).rounded()

    guard nanoseconds < Double(UInt64.max) else {
        return .max
    }

    return UInt64(nanoseconds)
}
