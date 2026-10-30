// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

@_spi(Testing) import SwiftAsyncStream
@_spi(Testing) import SwiftAsyncTesting
import Testing

// MARK: - Fixtures

/// Lets exactly one of several racing tasks find out it was first.
private actor FirstClaim {

    private var claimed = false

    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}

// MARK: - RegistryTests

/// The registry underneath `concurrent(_:)` and `concurrent(_:id:)`: same key returns the same
/// semaphore, different keys stay independent. End-to-end throttling is covered separately
/// below, through suites that actually apply the trait.
struct ConcurrentExecutionTraitRegistryTests {

    @Test
    func sameIDSharesOneSemaphoreInstance() {
        let first = ConcurrentExecutionTrait.semaphore(id: "registry-tests-shared", permits: 4)
        let second = ConcurrentExecutionTrait.semaphore(id: "registry-tests-shared", permits: 4)

        #expect(first === second)
    }

    @Test
    func differentIDsGetIndependentSemaphores() {
        let a = ConcurrentExecutionTrait.semaphore(id: "registry-tests-a", permits: 4)
        let b = ConcurrentExecutionTrait.semaphore(id: "registry-tests-b", permits: 4)

        #expect(a !== b)
    }

    /// Matches the limit `ConcurrentExecutionTraitUnnamedPoolThrottlingTests` declares for the
    /// unnamed pool below — the pool is process-wide, so a mismatched number here would trip
    /// the very precondition this trait uses to catch conflicting declarations.
    @Test
    func theUnnamedPoolIsIndependentFromEveryNamedPool() {
        let global = ConcurrentExecutionTrait.globalSemaphore(permits: 1)
        let named = ConcurrentExecutionTrait.semaphore(id: "registry-tests-not-global", permits: 1)

        #expect(global !== named)
    }

    // MARK: - Note
    //
    // Declaring the same pool twice with conflicting permit counts traps by design, so it has
    // no test here: Swift Testing has no way to assert a `precondition` failure without taking
    // the whole process down with it. The behaviour is documented on the trait and on the
    // registry itself.
}

// MARK: - Named pool throttling

/// Both tests ask for the same `id` with matching permits, so they share the exact semaphore
/// the suite trait created. Whichever runs first claims the single permit and confirms — via
/// `waitForWaiters`, not a sleep — that the other is genuinely queued behind it, which is only
/// possible if the trait is really wrapping test execution in that semaphore.
@Suite(.concurrent(1, id: "trait-tests-named-pool"))
struct ConcurrentExecutionTraitNamedPoolThrottlingTests {

    private static let release = AsyncSignal()
    private static let firstClaim = FirstClaim()

    @Test
    func firstTest() async throws {
        try await raceForThePermit()
    }

    @Test
    func secondTest() async throws {
        try await raceForThePermit()
    }

    private func raceForThePermit() async throws {
        let semaphore = ConcurrentExecutionTrait.semaphore(id: "trait-tests-named-pool", permits: 1)

        if await Self.firstClaim.claim() {
            try await semaphore.waitForWaiters(1, timeout: 300)
            Self.release.signal()
        } else {
            try await Self.release.wait()
        }
    }
}

// MARK: - Unnamed pool throttling

/// Same proof as above, this time through `concurrent(_:)`'s unnamed pool.
@Suite(.concurrent(1))
struct ConcurrentExecutionTraitUnnamedPoolThrottlingTests {

    private static let release = AsyncSignal()
    private static let firstClaim = FirstClaim()

    @Test
    func firstTest() async throws {
        try await raceForThePermit()
    }

    @Test
    func secondTest() async throws {
        try await raceForThePermit()
    }

    private func raceForThePermit() async throws {
        let semaphore = ConcurrentExecutionTrait.globalSemaphore(permits: 1)

        if await Self.firstClaim.claim() {
            try await semaphore.waitForWaiters(1, timeout: 300)
            Self.release.signal()
        } else {
            try await Self.release.wait()
        }
    }
}

// MARK: - Nil disables the trait

/// A `nil` executor is a mutual rendezvous: each test signals its own arrival and waits for the
/// other's. That only resolves if both are genuinely running at the same time — if `nil` still
/// applied a semaphore under the hood, whichever test ran second would never start, and the
/// first would time out waiting for a signal that never comes.
@Suite(.concurrent(nil))
struct ConcurrentExecutionTraitNilDisablesTheUnnamedPoolTests {

    private static let firstArrived = AsyncSignal()
    private static let secondArrived = AsyncSignal()

    @Test
    func firstTest() async throws {
        Self.firstArrived.signal()
        try await withTaskTimeout(seconds: 5) {
            try await Self.secondArrived.wait()
        }
    }

    @Test
    func secondTest() async throws {
        Self.secondArrived.signal()
        try await withTaskTimeout(seconds: 5) {
            try await Self.firstArrived.wait()
        }
    }
}

/// Same proof as above, through `concurrent(_:id:)`'s `nil` case.
@Suite(.concurrent(nil, id: "trait-tests-named-pool-nil"))
struct ConcurrentExecutionTraitNilDisablesTheNamedPoolTests {

    private static let firstArrived = AsyncSignal()
    private static let secondArrived = AsyncSignal()

    @Test
    func firstTest() async throws {
        Self.firstArrived.signal()
        try await withTaskTimeout(seconds: 5) {
            try await Self.secondArrived.wait()
        }
    }

    @Test
    func secondTest() async throws {
        Self.secondArrived.signal()
        try await withTaskTimeout(seconds: 5) {
            try await Self.firstArrived.wait()
        }
    }
}
