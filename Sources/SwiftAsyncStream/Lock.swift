#if canImport(Darwin)
import Darwin
import os
#else
import Glibc
#endif

/// A thread-safe lock that provides mutual exclusion using platform-specific locking mechanisms.
/// On Apple platforms (iOS, macOS, watchOS, tvOS), it uses `os_unfair_lock` for performance.
/// On other platforms (e.g., Linux), it uses `pthread_mutex` for portability.
public struct Lock: Sendable {

    private let storage = Storage()

    /// Creates a new instance of the lock.
    public init() {}

    /// Acquires the lock.
    /// This method blocks the calling thread until the lock can be acquired.
    public func lock() {
        storage.lock()
    }

    /// Releases the lock.
    /// The lock must be held by the calling thread, otherwise the behavior is undefined.
    public func unlock() {
        storage.unlock()
    }

    /// Acquires the lock, executes the given closure, and releases the lock.
    /// - Parameter block: A closure to execute while holding the lock.
    /// - Returns: The value returned by the closure.
    /// - Throws: Rethrows any error thrown by the closure.
    @discardableResult
    public func withLock<Output>(_ block: () throws -> Output) rethrows -> Output {
        lock()
        defer { unlock() }
        return try block()
    }

    /// Acquires the lock, executes the given closure, and releases the lock.
    /// - Parameter block: A closure to execute while holding the lock.
    /// - Throws: Rethrows any error thrown by the closure.
    public func withLockVoid(_ block: () throws -> Void) rethrows {
        try withLock(block)
    }
}

private extension Lock {

    final class Storage: @unchecked Sendable {
        #if canImport(Darwin)
        private var unfairLock = os_unfair_lock_s()
        #else
        private var mutex = pthread_mutex_t()
        #endif

        init() {
            #if !canImport(Darwin)
            var attr = pthread_mutexattr_t()
            pthread_mutexattr_init(&attr)
            pthread_mutexattr_settype(&attr, .init(PTHREAD_MUTEX_ERRORCHECK))
            pthread_mutex_init(&mutex, &attr)
            pthread_mutexattr_destroy(&attr)
            #endif
        }

        deinit {
            #if !canImport(Darwin)
            pthread_mutex_destroy(&mutex)
            #endif
        }

        func lock() {
            #if canImport(Darwin)
            os_unfair_lock_lock(&unfairLock)
            #else
            pthread_mutex_lock(&mutex)
            #endif
        }

        func unlock() {
            #if canImport(Darwin)
            os_unfair_lock_unlock(&unfairLock)
            #else
            pthread_mutex_unlock(&mutex)
            #endif
        }
    }
}
