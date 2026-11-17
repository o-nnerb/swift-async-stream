// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A counting semaphore whose waiters can leave the queue.
///
/// This is the cancellable sibling of ``AsyncSemaphore``. Both admit up to a fixed number of
/// tasks into a section at a time, and both serve waiters first in, first out. They differ in
/// what happens to a waiter that is cancelled.
///
/// ## Cancellation
///
/// ``AsyncSemaphore`` is cancellation transparent: a cancelled waiter still takes its turn,
/// runs, and returns its permit. That is the right contract when the permit is held for a short,
/// bounded time, because the queue is guaranteed to drain and nothing else is needed.
///
/// It is the wrong contract when permits can be held for as long as something outside the
/// program likes, such as requests in flight to a server. A waiter nobody wants anymore would
/// stay stuck behind everything ahead of it, only to give the slot straight back, and whoever is
/// behind it would wait one more hand-off.
///
/// Here, waiting is cancellable. A task cancelled while it waits leaves the queue and
/// ``wait(isolation:function:file:line:)`` throws `CancellationError`, without taking a permit.
/// That includes a task that was already cancelled before it asked. Everybody else keeps their
/// place: waiters are served in arrival order, and a returned permit goes straight to the first of
/// them instead of back to the count to be raced for.
///
/// A task that is handed a permit at the same moment it is cancelled wins the race and keeps the
/// permit: ``wait(isolation:function:file:line:)`` returns normally, and the permit is the
/// caller's to give back. This is why ``withPermit(isolation:function:file:line:_:)`` is the
/// intended entry point. It gives the permit back on every path, and only after a successful
/// wait.
///
/// ## Choosing between the two
///
/// - Use ``AsyncSemaphore`` when the section is short and every caller should run regardless of
///   cancellation.
/// - Use `AsyncCancellableSemaphore` when permits can be held for a long or unbounded time, or
///   when a cancelled caller has no use for a permit.
///
/// Since a cancelled waiter can always escape, a semaphore created with zero permits is a valid
/// gate here, which ``AsyncSemaphore`` warns against.
public final class AsyncCancellableSemaphore: Sendable {

    // MARK: - Inner types

    /// One suspended caller.
    ///
    /// Linked to its neighbours so that joining, leaving and being served are all constant time,
    /// however many are queued. A limit of one under a burst of work makes a long queue.
    private final class Waiter: @unchecked Sendable {

        enum State {
            /// Not in the queue yet, and not cancelled.
            case idle
            case waiting(UnsafeContinuation<Void, any Error>)
            case granted
            case cancelled
        }

        let debugInfo: AsyncOperation.DebugInfo

        var state = State.idle

        /// Not retained. The previous waiter is retained by its own predecessor's `next`, or by
        /// the queue's head, for exactly as long as this one is queued, so a strong reference
        /// here would only be a retain cycle between neighbours.
        unowned(unsafe) var previous: Waiter?

        var next: Waiter?

        init(debugInfo: AsyncOperation.DebugInfo) {
            self.debugInfo = debugInfo
        }
    }

    private final class Storage: @unchecked Sendable {

        var permits: Int
        var waitingCount = 0

        private var head: Waiter?
        private var tail: Waiter?

        init(permits: Int) {
            self.permits = permits
        }

        /// Every queued waiter, oldest first.
        var waiters: [Waiter] {
            var result = [Waiter]()
            var current = head

            while let waiter = current {
                result.append(waiter)
                current = waiter.next
            }

            return result
        }

        func enqueue(_ waiter: Waiter) {
            waiter.previous = tail

            if let tail {
                tail.next = waiter
            } else {
                head = waiter
            }

            tail = waiter
            waitingCount += 1
        }

        func dequeue(_ waiter: Waiter) {
            if let previous = waiter.previous {
                previous.next = waiter.next
            } else {
                head = waiter.next
            }

            if let next = waiter.next {
                next.previous = waiter.previous
            } else {
                tail = waiter.previous
            }

            waiter.previous = nil
            waiter.next = nil
            waitingCount -= 1
        }

        func popFirst() -> Waiter? {
            guard let waiter = head else {
                return nil
            }

            dequeue(waiter)
            return waiter
        }
    }

    private enum Outcome {
        case granted
        case cancelled
        case suspended
    }

    // MARK: - Public properties

    /// Permits currently available.
    public var availablePermits: Int {
        lock.withLock { _storage.permits }
    }

    /// Tasks currently waiting for a permit.
    public var waitingCount: Int {
        lock.withLock { _storage.waitingCount }
    }

    // MARK: - Private properties

    private let lock = Lock()

    // MARK: - Unsafe properties

    private let _storage: Storage

    // MARK: - Inits

    /// Creates a new AsyncCancellableSemaphore instance.
    /// - Parameter permits: How many tasks may hold a permit at the same time.
    public init(permits: Int) {
        precondition(permits >= .zero, "AsyncCancellableSemaphore requires a non negative permit count")
        _storage = .init(permits: permits)
    }

    // MARK: - Public methods

    /// Executes the provided closure while holding a permit.
    ///
    /// The permit is returned on every path out of the closure, and only if it was acquired.
    ///
    /// - Parameter isolation: The isolated execution `Actor`.
    /// - Parameter function: The caller's function name, captured for ``debugDescription``.
    /// - Parameter file: The caller's file, captured for ``debugDescription``.
    /// - Parameter line: The caller's line, captured for ``debugDescription``.
    /// - Parameter block: The closure to execute while holding the permit.
    /// - Returns: The result of the closure.
    /// - Throws: `CancellationError` if the current task is cancelled before it was handed a
    /// permit, in which case the closure never runs. Otherwise, whatever the closure throws.
    public func withPermit<Value: Sendable, Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ block: @Sendable () async throws(Failure) -> Value
    ) async throws -> Value {
        try await wait(isolation: isolation, function: function, file: file, line: line)
        defer { signal() }

        return try await block()
    }

    /// Executes the provided closure while holding a permit, without returning a value.
    ///
    /// The permit is returned on every path out of the closure, and only if it was acquired.
    ///
    /// - Parameter isolation: The isolated execution `Actor`.
    /// - Parameter function: The caller's function name, captured for ``debugDescription``.
    /// - Parameter file: The caller's file, captured for ``debugDescription``.
    /// - Parameter line: The caller's line, captured for ``debugDescription``.
    /// - Parameter block: The closure to execute while holding the permit.
    /// - Throws: `CancellationError` if the current task is cancelled before it was handed a
    /// permit, in which case the closure never runs. Otherwise, whatever the closure throws.
    public func withPermitVoid<Failure: Error>(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ block: @Sendable () async throws(Failure) -> Void
    ) async throws {
        try await wait(isolation: isolation, function: function, file: file, line: line)
        defer { signal() }

        try await block()
    }

    /// Acquires a permit, suspending until one is available.
    ///
    /// Every successful return must be paired with one call to ``signal()``. Prefer
    /// ``withPermit(isolation:function:file:line:_:)``, which does that for you.
    ///
    /// - Parameter isolation: The isolated execution `Actor`.
    /// - Parameter function: The caller's function name, captured for ``debugDescription``.
    /// - Parameter file: The caller's file, captured for ``debugDescription``.
    /// - Parameter line: The caller's line, captured for ``debugDescription``.
    /// - Throws: `CancellationError` if the current task is cancelled before it was handed a
    /// permit, including when it was cancelled before asking. No permit is taken in that case,
    /// so there is nothing to ``signal()``.
    public func wait(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) async throws {
        let waiter = Waiter(
            debugInfo: .init(function: function, file: file, line: line)
        )

        try await withTaskCancellationHandler(
            operation: {
                try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                    let outcome = lock.withLock { () -> Outcome in
                        // `onCancel` can run before this does, even before the task got here
                        // at all.
                        if case .cancelled = waiter.state {
                            return .cancelled
                        }

                        guard _storage.permits > .zero else {
                            waiter.state = .waiting(continuation)
                            _storage.enqueue(waiter)
                            return .suspended
                        }

                        _storage.permits -= 1
                        waiter.state = .granted
                        return .granted
                    }

                    switch outcome {
                    case .granted:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .suspended:
                        break
                    }
                }
            },
            onCancel: {
                cancel(waiter)
            },
            isolation: isolation
        )
    }

    /// Returns a permit, handing it to the first waiting task.
    public func signal() {
        let continuation = lock.withLock { () -> UnsafeContinuation<Void, any Error>? in
            // Handing the permit straight to a waiter rather than incrementing and letting it
            // race for the count.
            guard let waiter = _storage.popFirst() else {
                _storage.permits += 1
                return nil
            }

            guard case .waiting(let continuation) = waiter.state else {
                preconditionFailure("A queued waiter is always suspended")
            }

            waiter.state = .granted
            return continuation
        }

        continuation?.resume()
    }

    // MARK: - Private methods

    private func cancel(_ waiter: Waiter) {
        let continuation = lock.withLock { () -> UnsafeContinuation<Void, any Error>? in
            switch waiter.state {
            case .idle:
                waiter.state = .cancelled
                return nil
            case .waiting(let continuation):
                _storage.dequeue(waiter)
                waiter.state = .cancelled
                return continuation
            case .granted, .cancelled:
                // Already holds a permit, which is the caller's to give back.
                return nil
            }
        }

        continuation?.resume(throwing: CancellationError())
    }
}

// MARK: - CustomDebugStringConvertible

extension AsyncCancellableSemaphore: CustomDebugStringConvertible {

    /// A snapshot of the semaphore, naming how many permits are available and the call sites
    /// waiting for one.
    public var debugDescription: String {
        let (permits, pending) = lock.withLock {
            (_storage.permits, _storage.waiters.map(\.debugInfo))
        }

        let queue = pending.map { "  - \($0)" }.joined(separator: "\n")

        return """
            AsyncCancellableSemaphore
            available: \(permits)
            waiting (\(pending.count)):
            \(queue.isEmpty ? "  - none" : queue)
            """
    }
}

// MARK: - Testing

@_spi(Testing)
extension AsyncCancellableSemaphore {

    /// Suspends until ``waitingCount`` settles on `count`.
    ///
    /// Same reason as ``AsyncSemaphore/waitForWaiters(_:timeout:)``: task creation order is not
    /// task arrival order.
    public func waitForWaiters(_ count: Int, timeout: Double = 2) async throws {
        try await waitForCount(count, timeout: timeout) { waitingCount }
    }
}
