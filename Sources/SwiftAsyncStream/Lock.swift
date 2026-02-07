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
import os
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
/// - On Linux/Unix platforms: uses `pthread_mutex`.
/// - On Windows: uses `SRWLOCK`.
public struct Lock: Sendable {
    private let storage = Storage()

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
    /// - Parameter block: The closure to execute.
    /// - Returns: The value returned by the closure.
    /// - Throws: Errors thrown by the closure.
    @discardableResult
    public func withLock<Output>(_ block: () throws -> Output) rethrows -> Output {
        lock()
        defer { unlock() }
        return try block()
    }

    /// Executes the given closure while holding the lock (void return).
    /// - Parameter block: The closure to execute.
    /// - Throws: Errors thrown by the closure.
    public func withLockVoid(_ block: () throws -> Void) rethrows {
        try withLock(block)
    }
}

private extension Lock {
    final class Storage: @unchecked Sendable {
        #if os(Windows)
        private let mutex: UnsafeMutablePointer<SRWLOCK> = UnsafeMutablePointer.allocate(capacity: 1)

        #elseif os(WASI)
        // WASI threading support is experimental; this implementation assumes single-threaded execution.
        // For multithreaded WASI builds, integrate wasi_pthread locks when available.

        #elseif canImport(Darwin)
        private var unfairLock = os_unfair_lock_s()

        #else
        private let mutexPtr: UnsafeMutablePointer<pthread_mutex_t>
        #endif

        init() {
            #if os(Windows)
            InitializeSRWLock(mutex)

            #elseif os(WASI)
            // No initialization required for single-threaded WASI

            #elseif canImport(Darwin)
            // os_unfair_lock requires no explicit initialization

            #else
            mutexPtr = UnsafeMutablePointer.allocate(capacity: 1)
            mutexPtr.initialize(to: pthread_mutex_t())

            var attr = pthread_mutexattr_t()
            pthread_mutexattr_init(&attr)
            let err = pthread_mutex_init(mutexPtr, &attr)
            precondition(err == 0, "Failed to initialize pthread_mutex: \(err)")
            pthread_mutexattr_destroy(&attr)
            #endif
        }

        deinit {
            #if os(Windows)
            mutex.deallocate()

            #elseif os(WASI)
            // No cleanup required

            #elseif canImport(Darwin)
            // os_unfair_lock requires no explicit deinitialization

            #else
            let err = pthread_mutex_destroy(mutexPtr)
            precondition(err == 0, "Failed to destroy pthread_mutex: \(err)")
            mutexPtr.deallocate()
            #endif
        }

        func lock() {
            #if os(Windows)
            AcquireSRWLockExclusive(mutex)

            #elseif os(WASI)
            // No-op in single-threaded WASI

            #elseif canImport(Darwin)
            os_unfair_lock_lock(&unfairLock)

            #else
            let err = pthread_mutex_lock(mutexPtr)
            precondition(err == 0, "Failed to acquire pthread_mutex: \(err)")
            #endif
        }

        func unlock() {
            #if os(Windows)
            ReleaseSRWLockExclusive(mutex)

            #elseif os(WASI)
            // No-op in single-threaded WASI

            #elseif canImport(Darwin)
            os_unfair_lock_unlock(&unfairLock)

            #else
            let err = pthread_mutex_unlock(mutexPtr)
            precondition(err == 0, "Failed to release pthread_mutex: \(err)")
            #endif
        }
    }
}
