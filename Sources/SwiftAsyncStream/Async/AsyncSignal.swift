import Foundation

/// A synchronization primitive that allows tasks to wait for a signal before continuing execution.
/// It provides a way to coordinate between different asynchronous tasks.
public final class AsyncSignal: Sendable {

    private final class Storage: @unchecked Sendable {

        let lock = NSLock()

        var _isLocked = false
        var _pendingOperations = [AsyncOperation]()

        init(isLocked: Bool) {
            _isLocked = isLocked
        }

        deinit {
            while let operation = _pendingOperations.popLast() {
                operation.resume()
            }
        }
    }

    // MARK: - Unsafe properties

    private let storage: Storage

    // MARK: - Inits

    /// Creates a new AsyncSignal instance.
    /// - Parameter signal: Initial state of the signal. If true, the signal is already triggered.
    public init(_ signal: Bool = false) {
        storage = .init(isLocked: !signal)
    }

    // MARK: - Public properties

    /// Triggers the signal, allowing all waiting tasks to continue execution.
    public func signal() {
        storage.lock.withLock {
            storage._isLocked = false

            while let operation = storage._pendingOperations.popLast() {
                operation.resume()
            }
        }
    }

    /// Sets the signal to a locked state, blocking subsequent wait calls until signal() is called.
    public func lock() {
        storage.lock.withLock {
            storage._isLocked = true
        }
    }

    /// Waits for the signal to be triggered. If the signal is already triggered, this method returns immediately.
    public func wait() async {
        let operation = AsyncOperation()

        let lock = storage.lock
        weak var storage = storage

        await withTaskCancellationHandler {
            await withUnsafeContinuation {
                operation.schedule($0)

                lock.withLock {
                    guard storage?._isLocked ?? false else {
                        operation.resume()
                        return
                    }

                    guard storage?._pendingOperations.insert(operation, at: .zero) == nil else {
                        return
                    }

                    operation.resume()
                }
            }
        } onCancel: {
            lock.withLock {
                operation.cancelled()
            }
        }
    }
}
