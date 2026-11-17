// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@_spi(Testing) @testable import SwiftAsyncStream

/// A deliberately non-`Sendable` reference type.
///
/// What these tests pin down is that the primitives run on the caller's actor, so a caller can
/// hold non-`Sendable` actor state across `await`. A function that hopped off the caller's
/// actor would not even compile against this: passing the box into it would be a data race
/// diagnosis, and touching it afterwards would need a second hop back.
private final class Box {
    var value = 0
}

private final class Log {
    var entries: [String] = []
}

@globalActor
actor CustomCallerActor {
    static let shared = CustomCallerActor()
}

private struct Failure: Error, Equatable {
    let code: Int
}

/// Exercises every primitive from whichever actor `expected` is, on the contended path (the
/// call suspends and is resumed from an unrelated thread) as well as the uncontended one, and
/// checks after each `await` that the caller is still on that actor.
///
/// Written as `nonisolated(nonsending)` so it runs wherever the test calls it from, and so the
/// non-`Sendable` `box` can be handed in. No call below passes an `isolation:` argument.
private nonisolated(nonsending) func exerciseEveryPrimitive(
    expected: (any Actor)?,
    box: Box
) async throws {
    // `#isolation` is evaluated here, at the call, and not inside an `#expect` autoclosure,
    // which would be nonisolated and always see `nil`.
    func expectOnCallerActor(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ isolation: isolated (any Actor)? = #isolation
    ) {
        let onExpectedActor = isolation === expected
        #expect(onExpectedActor, "Continued on a different actor than the caller's", sourceLocation: sourceLocation)
    }

    // MARK: AsyncLock

    let lock = AsyncLock()

    expectOnCallerActor()

    await lock.lock()
    box.value += 1
    expectOnCallerActor()

    // Contended: held by this task, released by an unrelated one once this one is queued.
    let unlocker = Task.detached {
        try await lock.waitForPendingOperations(1)
        lock.unlock()
    }
    await lock.lock()
    try await unlocker.value
    box.value += 1
    expectOnCallerActor()
    lock.unlock()

    let locked = await lock.withLock { 7 }
    box.value += locked
    expectOnCallerActor()

    await lock.withLockVoid {}
    expectOnCallerActor()

    // Typed throws and `rethrows` keep working without an `isolation:` argument.
    do {
        _ = try await lock.withLock { () async throws(Failure) -> Int in
            throw Failure(code: 1)
        }
        Issue.record("withLock swallowed the error")
    } catch {
        #expect(error as? Failure == Failure(code: 1))
    }
    expectOnCallerActor()

    // The lock is free again after the throwing section.
    await lock.withLockVoid {}

    // MARK: AsyncSemaphore

    let semaphore = AsyncSemaphore(permits: 1)

    await semaphore.wait()
    box.value += 1
    expectOnCallerActor()

    let semaphoreReleaser = Task.detached {
        try await semaphore.waitForWaiters(1)
        semaphore.signal()
    }
    await semaphore.wait()
    try await semaphoreReleaser.value
    expectOnCallerActor()
    semaphore.signal()

    let permitted = await semaphore.withPermit { 3 }
    box.value += permitted
    expectOnCallerActor()

    await semaphore.withPermitVoid {}
    expectOnCallerActor()

    // MARK: AsyncCancellableSemaphore

    let cancellable = AsyncCancellableSemaphore(permits: 1)

    try await cancellable.wait()
    box.value += 1
    expectOnCallerActor()

    let cancellableReleaser = Task.detached {
        try await cancellable.waitForWaiters(1)
        cancellable.signal()
    }
    try await cancellable.wait()
    try await cancellableReleaser.value
    expectOnCallerActor()
    cancellable.signal()

    let cancellablePermitted = try await cancellable.withPermit { 5 }
    box.value += cancellablePermitted
    expectOnCallerActor()

    try await cancellable.withPermitVoid {}
    expectOnCallerActor()

    // MARK: AsyncSignal

    let signal = AsyncSignal()

    let opener = Task.detached {
        try await signal.waitForWaiters(1)
        signal.signal()
    }
    try await signal.wait()
    try await opener.value
    box.value += 1
    expectOnCallerActor()

    // Already open: the uncontended path.
    try await signal.wait()
    expectOnCallerActor()

    // MARK: Polling helper

    // The `value` closure reads non-`Sendable` actor state, which only compiles and only runs
    // correctly because `waitForCount` stays on the caller's actor.
    try await waitForCount(box.value, timeout: 1) { box.value }
    expectOnCallerActor()
}

// MARK: - Main actor

@MainActor
struct MainActorCallerIsolationTests {

    @Test
    func everyPrimitiveStaysOnTheMainActor() async throws {
        let box = Box()
        try await exerciseEveryPrimitive(expected: MainActor.shared, box: box)
        #expect(box.value > 0)
    }

    /// What actually distinguishes running on the caller's actor from hopping off it and back:
    /// an uncontended acquisition never suspends, so nothing else queued on the main actor can
    /// run in the middle of it. A function that hopped to the global executor would give the
    /// other task its turn, and `log` would read `["other", "caller"]`.
    @Test
    func uncontendedAcquisitionDoesNotYieldTheMainActor() async throws {
        let lock = AsyncLock()
        let semaphore = AsyncSemaphore(permits: 1)
        let cancellable = AsyncCancellableSemaphore(permits: 1)
        let signal = AsyncSignal(true)

        let log = Log()
        let other = Task { @MainActor in log.entries.append("other") }

        await lock.lock()
        await semaphore.wait()
        try await cancellable.wait()
        try await signal.wait()
        log.entries.append("caller")

        await other.value
        #expect(log.entries == ["caller", "other"])

        lock.unlock()
        semaphore.signal()
        cancellable.signal()
    }

    @Test
    func cancelledWaiterResumesOnTheMainActor() async throws {
        let semaphore = AsyncCancellableSemaphore(permits: 0)
        let box = Box()

        let waiter = Task { @MainActor in
            do {
                try await semaphore.wait()
                Issue.record("wait returned without a permit")
            } catch {
                #expect(error is CancellationError)
            }
            box.value += 1
            MainActor.assertIsolated()
        }

        try await semaphore.waitForWaiters(1)
        waiter.cancel()
        await waiter.value

        #expect(box.value == 1)
    }

    @Test
    func contendedWithPermitRunsItsContinuationOnTheMainActor() async {
        let semaphore = AsyncSemaphore(permits: 1)
        let box = Box()

        await semaphore.wait()

        let contender = Task { @MainActor in
            await semaphore.withPermitVoid {}
            box.value += 1
            MainActor.assertIsolated()
        }

        try? await semaphore.waitForWaiters(1)
        semaphore.signal()
        await contender.value

        #expect(box.value == 1)
    }
}

// MARK: - Custom global actor

@CustomCallerActor
struct CustomActorCallerIsolationTests {

    @Test
    func everyPrimitiveStaysOnTheCustomActor() async throws {
        let box = Box()
        try await exerciseEveryPrimitive(expected: CustomCallerActor.shared, box: box)
        #expect(box.value > 0)
    }
}

// MARK: - Plain nonisolated caller

struct NonisolatedCallerTests {

    /// Callers with no actor at all are unaffected: the primitives run on the global executor
    /// and `#isolation` is `nil`.
    @Test
    func everyPrimitiveStillWorksWithoutAnActor() async throws {
        let box = Box()
        try await exerciseEveryPrimitive(expected: nil, box: box)
    }
}
