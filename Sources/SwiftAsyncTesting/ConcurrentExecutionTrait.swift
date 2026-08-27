// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

// See AsyncExpectation.swift for why this whole module degrades to empty
// rather than breaking the build on SDKs without Testing.
#if canImport(Testing)
import SwiftAsyncStream
import Testing

/// Caps how many tests holding this trait may run at the same time, using an
/// ``AsyncSemaphore`` shared across every test or suite that names the same pool.
///
/// Two pools exist:
///
/// - The unnamed pool (``concurrent(_:)``), shared by every call site that omits `id`.
/// - A named pool per `id` (``concurrent(_:id:)``), isolated from the unnamed pool and from
///   every other `id`.
///
/// A pool's permit count is fixed by whichever call declares it first. Declaring the same pool
/// again with a different `executor` is a configuration mistake — not something to silently
/// resolve by taking the min or the max — so it traps instead of picking a value for you.
public struct ConcurrentExecutionTrait: TestTrait, SuiteTrait, TestScoping {

    public var isRecursive: Bool { true }

    private let semaphore: AsyncSemaphore

    fileprivate init(executor: Int, id: String?) {
        precondition(executor > .zero, "concurrent(_:) requires at least 1 concurrent execution slot")

        semaphore =
            id.map { Registry.shared.semaphore(id: $0, permits: executor) }
            ?? Registry.shared.globalSemaphore(permits: executor)
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await semaphore.withPermitVoid {
            try await function()
        }
    }
}

extension Trait where Self == ConcurrentExecutionTrait {

    /// Limits how many tests may run at once across every call site that also omits `id`,
    /// backed by one ``AsyncSemaphore`` shared globally.
    /// - Parameter executor: How many tests may hold this trait's permit at the same time.
    public static func concurrent(_ executor: Int) -> Self {
        Self(executor: executor, id: nil)
    }

    /// Limits how many tests may run at once across every call site sharing this `id`, backed
    /// by one ``AsyncSemaphore`` per `id`.
    /// - Parameter executor: How many tests may hold this trait's permit at the same time.
    /// - Parameter id: Identifies the shared pool. Every use of the same `id` must agree on the
    ///   same `executor`.
    public static func concurrent(_ executor: Int, id: String) -> Self {
        Self(executor: executor, id: id)
    }
}

// MARK: - Registry

extension ConcurrentExecutionTrait {

    /// Process-wide table of the pools backing ``concurrent(_:)`` and ``concurrent(_:id:)``,
    /// keyed by `id` — plus one slot for the unnamed pool.
    private final class Registry: @unchecked Sendable {

        static let shared = Registry()

        private struct Entry {
            let permits: Int
            let semaphore: AsyncSemaphore
        }

        private let lock = Lock()
        private var global: Entry?
        private var byID: [String: Entry] = [:]

        private init() {}

        func globalSemaphore(permits: Int) -> AsyncSemaphore {
            lock.withLock {
                if let global {
                    precondition(
                        global.permits == permits,
                        """
                        concurrent(_:) was declared with conflicting limits: \(global.permits) \
                        and \(permits). Every call site sharing the unnamed pool must agree on \
                        the same limit.
                        """
                    )
                    return global.semaphore
                }

                let entry = Entry(permits: permits, semaphore: AsyncSemaphore(permits: permits))
                global = entry
                return entry.semaphore
            }
        }

        func semaphore(id: String, permits: Int) -> AsyncSemaphore {
            lock.withLock {
                if let existing = byID[id] {
                    precondition(
                        existing.permits == permits,
                        """
                        concurrent(_:id:) for id "\(id)" was declared with conflicting limits: \
                        \(existing.permits) and \(permits). Every use of the same id must agree \
                        on the same limit.
                        """
                    )
                    return existing.semaphore
                }

                let entry = Entry(permits: permits, semaphore: AsyncSemaphore(permits: permits))
                byID[id] = entry
                return entry.semaphore
            }
        }
    }
}

// MARK: - Testing

@_spi(Testing)
extension ConcurrentExecutionTrait {

    /// Returns the semaphore backing the unnamed pool, creating it with `permits` if this is
    /// the first call. Lets a test prove the trait really throttles through this instance.
    public static func globalSemaphore(permits: Int) -> AsyncSemaphore {
        Registry.shared.globalSemaphore(permits: permits)
    }

    /// Returns the semaphore backing `id`'s pool, creating it with `permits` if this is the
    /// first call.
    public static func semaphore(id: String, permits: Int) -> AsyncSemaphore {
        Registry.shared.semaphore(id: id, permits: permits)
    }
}

#endif
