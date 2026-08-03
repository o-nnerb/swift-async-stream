// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

#if canImport(Darwin)
import Dispatch
#endif

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
/// - Note: The deadline bounds waiting, not the work itself. An operation that produces a
/// result returns it, even if it took longer than the deadline to get there.
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

    #if canImport(Darwin)
    let deadline = DispatchTime.now().uptimeNanoseconds &+ nanoseconds(from: seconds)
    #else
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    #endif

    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await body()
        }

        group.addTask {
            #if canImport(Darwin)
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                try await Task.sleep(nanoseconds: deadline - now)
            }
            #else
            try await Task.sleep(until: deadline, clock: .continuous)
            #endif

            throw TaskTimeoutError(seconds: seconds)
        }

        defer { group.cancelAll() }

        guard let value = try await group.next() else {
            throw CancellationError()
        }

        return value
    }
}

// MARK: - Private methods

#if canImport(Darwin)
private func nanoseconds(from seconds: Double) -> UInt64 {
    let nanoseconds = (seconds * 1_000_000_000).rounded()

    guard nanoseconds < Double(UInt64.max) else {
        return .max
    }

    return UInt64(nanoseconds)
}
#endif
