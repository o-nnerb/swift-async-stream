//===----------------------------------------------------------------------===//
//
// This source file is derived from the SwiftNIO open source project
//
// Copyright (c) 2017-2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// Modifications Copyright (c) 2026 Brenno Giovanini de Moura
//
// See LICENSE.txt for license information
// Original source: https://github.com/apple/swift-nio/blob/main/Sources/NIOConcurrencyHelpers/lock.swift
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

#if canImport(Darwin)
import Darwin
import os.lock
#elseif os(Windows)
import ucrt
import WinSDK
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#if canImport(wasi_pthread)
import wasi_pthread
#endif
#else
#error("The Lock module was unable to identify your C library. Supported libraries are Glibc, Musl, Bionic, WASILibc, Darwin, and Windows SDK.")
#endif

/// A thread-safe lock that provides mutual exclusion using platform-specific locking mechanisms.
/// - On Apple platforms: uses `os_unfair_lock` for performance.
/// - On Linux/Unix platforms: uses `pthread_mutex` with error checking in debug builds.
/// - On Windows: uses `SRWLOCK`.
/// - On WASI: no-op in single-threaded environments; uses pthread when available.
public struct Lock: Sendable {
    private let storage = Storage()

    /// Creates a new lock instance.
    public init() {}

    /// Acquires the lock, blocking the calling thread until the lock is available.
    public func lock() {
        storage.lock()
    }

    /// Releases the lock. The calling thread must hold the lock.
    public func unlock() {
        storage.unlock()
    }

    /// Executes the given closure while holding the lock.
    /// - Parameter body: The closure to execute.
    /// - Returns: The value returned by the closure.
    /// - Throws: Errors thrown by the closure.
    @discardableResult
    public func withLock<Output>(_ body: () throws -> Output) rethrows -> Output {
        lock()
        defer { unlock() }
        return try body()
    }

    /// Executes the given closure while holding the lock (void return).
    /// - Parameter body: The closure to execute.
    /// - Throws: Errors thrown by the closure.
    public func withLockVoid(_ body: () throws -> Void) rethrows {
        try withLock(body)
    }
}

// MARK: - Storage Implementation

private extension Lock {
    final class Storage: @unchecked Sendable {
        #if os(Windows)
        private let mutex: UnsafeMutablePointer<SRWLOCK> =
            UnsafeMutablePointer.allocate(capacity: 1)

        #elseif os(WASI)
        #if canImport(wasi_pthread)
        private let mutexPtr: UnsafeMutablePointer<pthread_mutex_t>
        #endif
        // Single-threaded WASI requires no storage

        #elseif canImport(Darwin)
        private var unfairLock = os_unfair_lock()

        #elseif os(OpenBSD)
        // OpenBSD uses nullable pthread_mutex_t
        private let mutexPtr: UnsafeMutablePointer<pthread_mutex_t?>

        #else
        private let mutexPtr: UnsafeMutablePointer<pthread_mutex_t>
        #endif

        init() {
            #if os(Windows)
            InitializeSRWLock(mutex)

            #elseif os(WASI)
            #if canImport(wasi_pthread)
            mutexPtr = UnsafeMutablePointer.allocate(capacity: 1)
            mutexPtr.initialize(to: pthread_mutex_t())
            initializePThreadMutex(mutexPtr)
            #endif

            #elseif canImport(Darwin)
            // os_unfair_lock requires no explicit initialization

            #elseif os(OpenBSD)
            mutexPtr = UnsafeMutablePointer.allocate(capacity: 1)
            mutexPtr.initialize(to: nil)
            initializePThreadMutex(mutexPtr)

            #else
            mutexPtr = UnsafeMutablePointer.allocate(capacity: 1)
            mutexPtr.initialize(to: pthread_mutex_t())
            initializePThreadMutex(mutexPtr)
            #endif
        }

        deinit {
            #if os(Windows)
            mutex.deallocate()

            #elseif os(WASI)
            #if canImport(wasi_pthread)
            destroyAndDeallocatePThreadMutex(mutexPtr)
            #endif

            #elseif canImport(Darwin)
            // os_unfair_lock requires no explicit deinitialization

            #elseif os(OpenBSD) || canImport(Glibc) || canImport(Musl) || canImport(Bionic)
            destroyAndDeallocatePThreadMutex(mutexPtr)
            #endif
        }

        func lock() {
            #if os(Windows)
            AcquireSRWLockExclusive(mutex)

            #elseif os(WASI)
            #if canImport(wasi_pthread)
            let err = pthread_mutex_lock(mutexPtr)
            precondition(err == 0, "Failed to acquire pthread_mutex: \(err)")
            #endif
            // No-op in single-threaded WASI

            #elseif canImport(Darwin)
            os_unfair_lock_lock(&unfairLock)

            #elseif os(OpenBSD)
            let err = pthread_mutex_lock(mutexPtr)
            precondition(err == 0, "Failed to acquire pthread_mutex: \(err)")

            #else
            let err = pthread_mutex_lock(mutexPtr)
            precondition(err == 0, "Failed to acquire pthread_mutex: \(err)")
            #endif
        }

        func unlock() {
            #if os(Windows)
            ReleaseSRWLockExclusive(mutex)

            #elseif os(WASI)
            #if canImport(wasi_pthread)
            let err = pthread_mutex_unlock(mutexPtr)
            precondition(err == 0, "Failed to release pthread_mutex: \(err)")
            #endif
            // No-op in single-threaded WASI

            #elseif canImport(Darwin)
            os_unfair_lock_unlock(&unfairLock)

            #elseif os(OpenBSD)
            let err = pthread_mutex_unlock(mutexPtr)
            precondition(err == 0, "Failed to release pthread_mutex: \(err)")

            #else
            let err = pthread_mutex_unlock(mutexPtr)
            precondition(err == 0, "Failed to release pthread_mutex: \(err)")
            #endif
        }

        // MARK: - pthread Helpers (Linux/Unix)

        #if os(OpenBSD) || canImport(Glibc) || canImport(Musl) || canImport(Bionic) || (os(WASI) && canImport(wasi_pthread))
        private func initializePThreadMutex(_ ptr: UnsafeMutablePointer<pthread_mutex_t>) {
            var attr = pthread_mutexattr_t()
            pthread_mutexattr_init(&attr)
            debugOnly {
                #if !os(OpenBSD)
                pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_ERRORCHECK)
                #endif
            }
            let err = pthread_mutex_init(ptr, &attr)
            precondition(err == 0, "Failed to initialize pthread_mutex: \(err)")
            pthread_mutexattr_destroy(&attr)
        }

        #if os(OpenBSD)
        private func initializePThreadMutex(_ ptr: UnsafeMutablePointer<pthread_mutex_t?>) {
            var attr = pthread_mutexattr_t(bitPattern: 0)
            pthread_mutexattr_init(&attr)
            let err = pthread_mutex_init(ptr, &attr)
            precondition(err == 0, "Failed to initialize pthread_mutex: \(err)")
            pthread_mutexattr_destroy(&attr)
        }
        #endif

        private func destroyAndDeallocatePThreadMutex(_ ptr: UnsafeMutablePointer<pthread_mutex_t>) {
            let err = pthread_mutex_destroy(ptr)
            precondition(err == 0, "Failed to destroy pthread_mutex: \(err)")
            ptr.deallocate()
        }

        #if os(OpenBSD)
        private func destroyAndDeallocatePThreadMutex(_ ptr: UnsafeMutablePointer<pthread_mutex_t?>) {
            let err = pthread_mutex_destroy(ptr)
            precondition(err == 0, "Failed to destroy pthread_mutex: \(err)")
            ptr.deallocate()
        }
        #endif
        #endif
    }
}

// MARK: - Debug Utilities

/// Executes the given closure only in debug builds.
///
/// This is currently the only way to do this in Swift without compiler warnings.
/// See: https://forums.swift.org/t/support-debug-only-code/11037
private func debugOnly(_ body: () -> Void) {
    assert({ body(); return true }())
}
