import Foundation

/// A synchronization primitive that provides mutual exclusion for asynchronous operations.
/// It allows only one task to access a critical section at a time.
public final class AsyncLock: Sendable {

    private final class Storage: @unchecked Sendable {

        var isLocked = false
        var pendingOperations = [AsyncOperation]()

        deinit {
            while let operation = pendingOperations.popLast() {
                operation.resume()
            }
        }
    }

    // MARK: - Private properties

    private let lock = Lock()

    // MARK: - Unsafe properties

    private let _storage = Storage()

    /// Creates a new AsyncLock instance.
    public init() {}

    // MARK: - Public properties

    /// Executes the provided closure while maintaining the lock.
    /// - Parameter block: The closure to execute while holding the lock.
    /// - Returns: The result of the closure.
    public func withLock<Value: Sendable>(isolation: isolated (any Actor)? = #isolation, _ block: @Sendable () async throws -> Value) async rethrows -> Value {
        await lock()
        defer { unlock() }

        return try await block()
    }

    /// Executes the provided closure while maintaining the lock, without returning a value.
    /// - Parameter block: The closure to execute while holding the lock.
    public func withLockVoid(isolation: isolated (any Actor)? = #isolation, _ block: @Sendable () async throws -> Void) async rethrows {
        await lock()
        defer { unlock() }

        try await block()
    }

    /// Unlocks the lock and allows the next waiting operation to proceed.
    public func unlock() {
        lock.withLock {
            guard _storage.isLocked else {
                return
            }

            var scheduledOperation: AsyncOperation?

            while let operation = _storage.pendingOperations.popLast() {
                if !operation.isScheduled {
                    continue
                }

                scheduledOperation = operation
                break
            }

            _storage.isLocked = !_storage.pendingOperations.isEmpty

            scheduledOperation?.resume()
        }
    }

    /// Acquires the lock. If the lock is already held by another task, this method will suspend
    /// until the lock becomes available.
    public func lock() async {
        let operation = AsyncOperation()

        let lock = lock
        weak var storage = _storage

        await withTaskCancellationHandler {
            await withUnsafeContinuation {
                operation.schedule($0)

                lock.withLock {
                    guard let storage else {
                        operation.resume()
                        return
                    }

                    guard storage.isLocked else {
                        storage.isLocked = true
                        operation.resume()
                        return
                    }

                    storage.pendingOperations.insert(operation, at: .zero)
                }
            }
        } onCancel: {
            lock.withLock {
                operation.cancelled()
            }
        }
    }
}
