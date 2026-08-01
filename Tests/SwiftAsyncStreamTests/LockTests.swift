// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SwiftAsyncStream

struct LockTests {

    @Test
    func mutualExclusionUnderConcurrency() async {
        let lock = Lock()
        let counter = InlineProperty(wrappedValue: 0)
        let iterations = 5000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    lock.withLock {
                        counter.wrappedValue += 1
                    }
                }
            }
        }

        #expect(counter.wrappedValue == iterations)
    }

    @Test
    func withLockReturnsTheClosureValue() {
        let lock = Lock()

        let result = lock.withLock { 7 * 6 }

        #expect(result == 42)
    }

    @Test
    func withLockPropagatesTheClosuresError() {
        let lock = Lock()

        struct TestError: Error {}

        #expect(throws: TestError.self) {
            try lock.withLock {
                throw TestError()
            }
        }
    }

    @Test
    func withLockVoidRunsTheClosure() {
        let lock = Lock()
        var called = false

        lock.withLockVoid {
            called = true
        }

        #expect(called)
    }

    @Test
    func manualLockUnlockAlternates() {
        let lock = Lock()
        var counter = 0

        lock.lock()
        counter += 1
        lock.unlock()

        lock.lock()
        counter += 1
        lock.unlock()

        #expect(counter == 2)
    }
}
