// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SwiftAsyncStream

/// A small deterministic generator, seeded so the stress test below reproduces the same
/// sequence of operations on every run.
private struct SplitMix64: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct FIFOQueueTests {

    @Test
    func startsEmpty() {
        var queue = FIFOQueue<Int>()

        #expect(queue.isEmpty)
        #expect(queue.count == .zero)
        #expect(queue.popFirst() == nil)
    }

    @Test
    func popsInTheOrderElementsWereAppended() {
        var queue = FIFOQueue<Int>()

        queue.append(1)
        queue.append(2)
        queue.append(3)

        #expect(queue.count == 3)
        #expect(queue.elements == [1, 2, 3])
        #expect(queue.popFirst() == 1)
        #expect(queue.popFirst() == 2)
        #expect(queue.popFirst() == 3)
        #expect(queue.popFirst() == nil)
        #expect(queue.isEmpty)
    }

    @Test
    func interleavesAppendAndPopCorrectly() {
        var queue = FIFOQueue<Int>()

        queue.append(1)
        queue.append(2)
        #expect(queue.popFirst() == 1)

        queue.append(3)
        #expect(queue.elements == [2, 3])
        #expect(queue.popFirst() == 2)
        #expect(queue.popFirst() == 3)
        #expect(queue.popFirst() == nil)
    }

    @Test
    func removeAllDropsMatchingElementsAndKeepsTheRestInOrder() {
        var queue = FIFOQueue<Int>()

        for value in 1...10 {
            queue.append(value)
        }

        queue.removeAll { $0 % 3 == .zero }

        #expect(queue.elements == [1, 2, 4, 5, 7, 8, 10])
        #expect(queue.count == 7)
    }

    @Test
    func removeAllOnAnEmptyQueueIsANoOp() {
        var queue = FIFOQueue<Int>()

        queue.removeAll { _ in true }

        #expect(queue.isEmpty)
    }

    @Test
    func drainReturnsEveryElementInOrderAndEmptiesTheQueue() {
        var queue = FIFOQueue<Int>()

        queue.append(1)
        queue.append(2)
        queue.append(3)

        let drained = queue.drain()

        #expect(drained == [1, 2, 3])
        #expect(queue.isEmpty)
        #expect(queue.popFirst() == nil)
    }

    @Test
    func staysConsistentWithAnArrayBasedReferenceAcrossManyOperations() {
        var queue = FIFOQueue<Int>()
        var reference = [Int]()
        var rng = SplitMix64(seed: 42)
        var nextValue = 0

        for _ in 0..<5000 {
            switch rng.next() % 4 {
            case 0:
                queue.append(nextValue)
                reference.append(nextValue)
                nextValue += 1

            case 1:
                #expect(queue.popFirst() == (reference.isEmpty ? nil : reference.removeFirst()))

            case 2:
                let threshold = Int(rng.next() % 7)
                queue.removeAll { $0 % 7 == threshold }
                reference.removeAll { $0 % 7 == threshold }

            default:
                #expect(queue.drain() == reference)
                reference.removeAll()
            }

            #expect(queue.count == reference.count)
            #expect(queue.elements == reference)
        }
    }
}
