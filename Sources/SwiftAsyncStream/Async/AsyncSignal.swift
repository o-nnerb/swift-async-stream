// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A manual reset event. Tasks calling ``wait(isolation:function:file:line:)`` suspend while
/// the signal is closed, and are all released at once by ``signal()``.
///
/// ## Cancellation
///
/// Unlike ``AsyncLock``, there is no guarantee that a waiting task will ever be released:
/// ``signal()`` may never be called. Waiting is therefore cancellable, and
/// ``wait(isolation:function:file:line:)`` throws `CancellationError` when the current task is
/// cancelled before the signal arrives.
public final class AsyncSignal: Sendable {

    // MARK: - Inner types

    private final class Storage: @unchecked Sendable {

        var isLocked: Bool
        var pendingOperations = FIFOQueue<AsyncOperation>()

        init(isLocked: Bool) {
            self.isLocked = isLocked
        }

        deinit {
            // Safety net. Nothing can signal anymore, so every queued operation is released
            // instead of being left suspended forever.
            while let operation = pendingOperations.popFirst() {
                operation.run()?.resume()
            }
        }
    }

    // MARK: - Private properties

    private let locker = Lock()

    // MARK: - Unsafe properties

    private let _storage: Storage

    // MARK: - Inits

    /// Creates a new AsyncSignal instance.
    /// - Parameter signal: `true` starts the signal open, so `wait()` returns immediately.
    public init(_ signal: Bool = false) {
        _storage = .init(isLocked: !signal)
    }

    // MARK: - Public methods

    /// Opens the signal and releases every waiting task.
    public func signal() {
        let continuations = locker.withLock { () -> [UnsafeContinuation<Void, Never>] in
            _storage.isLocked = false
            return _storage.pendingOperations.drain().compactMap { $0.run() }
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    /// Closes the signal. Subsequent calls to `wait()` suspend until the next `signal()`.
    public func lock() {
        locker.withLock {
            _storage.isLocked = true
        }
    }

    /// Suspends until the signal is open.
    /// - Throws: `CancellationError` when the current task is cancelled while waiting.
    public func wait(
        isolation: isolated (any Actor)? = #isolation,
        function: StaticString = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) async throws(CancellationError) {
        let operation = AsyncOperation(
            debugInfo: .init(function: function, file: file, line: line)
        )

        await withTaskCancellationHandler(
            operation: {
                await withUnsafeContinuation(isolation: isolation) { continuation in
                    let resumable = locker.withLock { () -> UnsafeContinuation<Void, Never>? in
                        guard operation.schedule(continuation) else {
                            // Cancelled before it could be scheduled. Resume right away so the
                            // caller observes the cancellation instead of suspending forever.
                            return continuation
                        }

                        guard _storage.isLocked else {
                            return operation.run()
                        }

                        _storage.pendingOperations.append(operation)
                        return nil
                    }

                    resumable?.resume()
                }
            },
            onCancel: {
                self.cancel(operation)
            },
            isolation: isolation
        )

        if operation.state == .cancelled {
            throw CancellationError()
        }
    }

    // MARK: - Private methods

    private func cancel(_ operation: AsyncOperation) {
        let continuation = locker.withLock { () -> UnsafeContinuation<Void, Never>? in
            guard let continuation = operation.cancel() else {
                // Already released by `signal()`.
                return nil
            }

            _storage.pendingOperations.removeAll { $0 === operation }
            return continuation
        }

        continuation?.resume()
    }
}

// MARK: - CustomDebugStringConvertible

extension AsyncSignal: CustomDebugStringConvertible {

    public var debugDescription: String {
        let (isLocked, pending) = locker.withLock {
            (_storage.isLocked, _storage.pendingOperations.elements)
        }

        let queue = pending.map { "  - \($0)" }.joined(separator: "\n")

        return """
            AsyncSignal
            state: \(isLocked ? "locked" : "signalled")
            pending (\(pending.count)):
            \(queue.isEmpty ? "  - none" : queue)
            """
    }
}
