// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A synchronization primitive that provides mutual exclusion for asynchronous operations.
/// It allows only one task to access a critical section at a time.
///
/// ## Cancellation
///
/// The lock is cancellation transparent. Acquisition is never aborted, so a task cancelled
/// while waiting still takes its turn, runs the critical section and releases the lock. Use
/// `try Task.checkCancellation()` inside the block to bail out early.
///
/// That contract is safe here only because releasing is guaranteed by `defer`. Primitives with
/// no such guarantee, such as ``AsyncSignal``, have to be cancellable instead.
public final class AsyncLock: Sendable {

    // MARK: - Inner types

    /// Reports critical sections that outstay their welcome.
    ///
    /// Meant for development builds. A lock that stops being released produces no error, no
    /// crash and no log, only tasks that quietly stop making progress, so the only way to learn
    /// about it early is to ask.
    public struct Watchdog: Sendable {

        /// How long a critical section may run before being reported.
        public let seconds: Double

        /// Receives the lock's ``AsyncLock/debugDescription`` when the deadline passes.
        public let report: @Sendable (String) -> Void

        /// Creates a watchdog.
        /// - Parameters:
        ///   - seconds: How long a critical section may run before being reported.
        ///   - report: Receives a description naming the holder and everyone queued behind it.
        ///   Defaults to printing. Wire it to `Issue.record` in a test target.
        public init(
            seconds: Double,
            report: @escaping @Sendable (String) -> Void = { print("⚠️ \($0)") }
        ) {
            precondition(seconds > .zero, "AsyncLock.Watchdog requires a positive deadline")
            self.seconds = seconds
            self.report = report
        }
    }

    private final class Storage: @unchecked Sendable {

        var runningOperation: AsyncOperation?
        var pendingOperations = FIFOQueue<AsyncOperation>()

        deinit {
            // Safety net. Nothing can hand the lock over anymore, so every queued operation
            // is released instead of being left suspended forever.
            while let operation = pendingOperations.popFirst() {
                operation.run()?.resume()
            }
        }
    }

    private struct Handoff {
        let operation: AsyncOperation
        let continuation: UnsafeContinuation<Void, Never>
    }

    // MARK: - Private properties

    private let lock = Lock()
    private let watchdog: Watchdog?

    // MARK: - Unsafe properties

    private let _storage = Storage()

    // MARK: - Inits

    /// Creates a new AsyncLock instance.
    /// - Parameter watchdog: Reports critical sections that run longer than a deadline. `nil`,
    /// the default, disables the check entirely and costs nothing.
    public init(watchdog: Watchdog? = nil) {
        self.watchdog = watchdog
    }

    // MARK: - Public methods

    /// Executes the provided closure while maintaining the lock.
    /// - Parameter isolation: The isolated execution `Actor`.
    /// - Parameter block: The closure to execute while holding the lock.
    /// - Returns: The result of the closure.
    public func withLock<Value: Sendable, Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ block: @Sendable () async throws(Failure) -> Value
    ) async rethrows -> Value {
        await lock(isolation: isolation, function: function, file: file, line: line)
        defer { unlock() }

        return try await block()
    }

    /// Executes the provided closure while maintaining the lock, without returning a value.
    /// - Parameter isolation: The isolated execution `Actor`.
    /// - Parameter block: The closure to execute while holding the lock.
    public func withLockVoid<Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ block: @Sendable () async throws(Failure) -> Void
    ) async rethrows {
        await lock(isolation: isolation, function: function, file: file, line: line)
        defer { unlock() }

        try await block()
    }

    /// Acquires the lock. If the lock is already held by another task, this method will suspend
    /// until the lock becomes available.
    public func lock(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) async {
        let operation = AsyncOperation(
            debugInfo: .init(function: function, file: file, line: line)
        )

        await withUnsafeContinuation(isolation: isolation) { continuation in
            let handoff = lock.withLock { () -> Handoff? in
                operation.schedule(continuation)

                guard _storage.runningOperation == nil else {
                    _storage.pendingOperations.append(operation)
                    return nil
                }

                guard let running = operation.run() else {
                    return nil
                }

                _storage.runningOperation = operation
                return Handoff(operation: operation, continuation: running)
            }

            resume(handoff)
        }
    }

    /// Unlocks the lock and allows the next waiting operation to proceed.
    public func unlock() {
        let handoff = lock.withLock { () -> Handoff? in
            guard _storage.runningOperation != nil else {
                return nil
            }

            _storage.runningOperation = nil
            return _dequeue()
        }

        resume(handoff)
    }

    // MARK: - Private methods

    private func resume(_ handoff: Handoff?) {
        guard let handoff else {
            return
        }

        startWatchdog(for: handoff.operation)
        handoff.continuation.resume()
    }

    private func startWatchdog(for operation: AsyncOperation) {
        guard let watchdog else {
            return
        }

        let nanoseconds = UInt64(watchdog.seconds * 1_000_000_000)

        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard let self, self.isHolding(operation) else {
                return
            }

            watchdog.report(
                "AsyncLock held for more than \(watchdog.seconds)s\n\(self.debugDescription)"
            )
        }
    }

    private func isHolding(_ operation: AsyncOperation) -> Bool {
        lock.withLock { _storage.runningOperation === operation }
    }

    // MARK: - Unsafe methods

    /// Promotes the next pending operation into the running slot.
    /// - Warning: Lockless. The caller must be holding ``lock``.
    private func _dequeue() -> Handoff? {
        while let operation = _storage.pendingOperations.popFirst() {
            guard let continuation = operation.run() else {
                continue
            }

            _storage.runningOperation = operation
            return Handoff(operation: operation, continuation: continuation)
        }

        return nil
    }
}

// MARK: - CustomDebugStringConvertible

extension AsyncLock: CustomDebugStringConvertible {

    public var debugDescription: String {
        let (running, pending) = lock.withLock {
            (_storage.runningOperation, _storage.pendingOperations.elements)
        }

        let holder = running.map(String.init(describing:)) ?? "none"
        let queue = pending.map { "  - \($0)" }.joined(separator: "\n")

        return """
            AsyncLock
            holder: \(holder)
            pending (\(pending.count)):
            \(queue.isEmpty ? "  - none" : queue)
            """
    }
}

// MARK: - Testing

@_spi(Testing)
extension AsyncLock {

    /// Operations waiting for the lock. The holder is not counted.
    public var pendingCount: Int {
        lock.withLock { _storage.pendingOperations.count }
    }

    /// Suspends until ``pendingCount`` settles on `count`.
    ///
    /// Creating a `Task` does not decide when it reaches the lock, so a test that needs a
    /// known queue order has to admit one waiter at a time and confirm its arrival, rather
    /// than creating them all at once and assuming creation order is arrival order.
    public func waitForPendingOperations(_ count: Int, timeout: Double = 2) async throws {
        try await waitForCount(count, timeout: timeout) { pendingCount }
    }
}
