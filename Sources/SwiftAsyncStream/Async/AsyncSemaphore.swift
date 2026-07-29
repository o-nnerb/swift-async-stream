// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A counting semaphore for asynchronous operations, allowing up to a fixed number of tasks
/// into a section at a time.
///
/// ## Cancellation
///
/// Like ``AsyncLock``, and for the same reason, waiting is cancellation transparent: a task
/// cancelled while waiting still takes its turn, runs, and returns its permit. That guarantee
/// rests entirely on every permit being returned, which is why
/// ``withPermit(isolation:function:file:line:_:)`` is the intended entry point.
///
/// - Warning: Do not use this as an event by starting it at zero permits and signalling from
/// elsewhere. Nothing guarantees the signal ever arrives, so a cancelled waiter would never
/// escape. ``AsyncSignal`` exists for that and is cancellable precisely because it has no such
/// guarantee.
public final class AsyncSemaphore: Sendable {

    // MARK: - Inner types

    private final class Storage: @unchecked Sendable {

        var permits: Int
        var pendingOperations = FIFOQueue<AsyncOperation>()

        init(permits: Int) {
            self.permits = permits
        }

        deinit {
            // Safety net. Nothing can hand a permit over anymore, so every queued operation is
            // released instead of being left suspended forever.
            while let operation = pendingOperations.popFirst() {
                operation.run()?.resume()
            }
        }
    }

    // MARK: - Public properties

    /// Permits currently available.
    public var availablePermits: Int {
        lock.withLock { _storage.permits }
    }

    /// Tasks currently waiting for a permit.
    public var waitingCount: Int {
        lock.withLock { _storage.pendingOperations.count }
    }

    // MARK: - Private properties

    private let lock = Lock()

    // MARK: - Unsafe properties

    private let _storage: Storage

    // MARK: - Inits

    /// Creates a new AsyncSemaphore instance.
    /// - Parameter permits: How many tasks may hold a permit at the same time.
    public init(permits: Int) {
        precondition(permits >= .zero, "AsyncSemaphore requires a non negative permit count")
        _storage = .init(permits: permits)
    }

    // MARK: - Public methods

    /// Executes the provided closure while holding a permit.
    /// - Parameter isolation: The isolated execution `Actor`.
    /// - Parameter block: The closure to execute while holding the permit.
    /// - Returns: The result of the closure.
    public func withPermit<Value: Sendable, Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ block: @Sendable () async throws(Failure) -> Value
    ) async rethrows -> Value {
        await wait(isolation: isolation, function: function, file: file, line: line)
        defer { signal() }

        return try await block()
    }

    /// Executes the provided closure while holding a permit, without returning a value.
    /// - Parameter isolation: The isolated execution `Actor`.
    /// - Parameter block: The closure to execute while holding the permit.
    public func withPermitVoid<Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ block: @Sendable () async throws(Failure) -> Void
    ) async rethrows {
        await wait(isolation: isolation, function: function, file: file, line: line)
        defer { signal() }

        try await block()
    }

    /// Acquires a permit, suspending until one is available.
    public func wait(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) async {
        let operation = AsyncOperation(
            debugInfo: .init(function: function, file: file, line: line)
        )

        await withUnsafeContinuation(isolation: isolation) { continuation in
            let acquired = lock.withLock { () -> UnsafeContinuation<Void, Never>? in
                operation.schedule(continuation)

                guard _storage.permits > .zero else {
                    _storage.pendingOperations.append(operation)
                    return nil
                }

                _storage.permits -= 1
                return operation.run()
            }

            acquired?.resume()
        }
    }

    /// Returns a permit, letting the next waiting task proceed.
    public func signal() {
        let continuation = lock.withLock { () -> UnsafeContinuation<Void, Never>? in
            // Handing the permit straight to a waiter rather than incrementing and letting it
            // race for the count.
            while let operation = _storage.pendingOperations.popFirst() {
                guard let continuation = operation.run() else {
                    continue
                }

                return continuation
            }

            _storage.permits += 1
            return nil
        }

        continuation?.resume()
    }
}

// MARK: - CustomDebugStringConvertible

extension AsyncSemaphore: CustomDebugStringConvertible {

    public var debugDescription: String {
        let (permits, pending) = lock.withLock {
            (_storage.permits, _storage.pendingOperations.elements)
        }

        let queue = pending.map { "  - \($0)" }.joined(separator: "\n")

        return """
            AsyncSemaphore
            available: \(permits)
            waiting (\(pending.count)):
            \(queue.isEmpty ? "  - none" : queue)
            """
    }
}

// MARK: - Testing

@_spi(Testing)
public extension AsyncSemaphore {

    /// Suspends until ``waitingCount`` settles on `count`.
    ///
    /// Same reason as ``AsyncLock/waitForPendingOperations(_:timeout:)``: task creation order
    /// is not task arrival order.
    func waitForWaiters(_ count: Int, timeout: Double = 2) async throws {
        try await waitForCount(count, timeout: timeout) { waitingCount }
    }
}
