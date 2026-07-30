// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import SwiftAsyncStream

struct NodeChainTests {

    // MARK: - Buffering

    @Test
    func unboundedChainNeverDropsAnything() {
        let chain = NodeChain<Int>(policy: .unbounded)

        for value in 1...10 {
            chain.produce(value)
        }

        #expect(chain.count == 10)
    }

    @Test
    func bufferingNewestTrimsDownToTheLimit() {
        let chain = NodeChain<Int>(policy: .bufferingNewest(3))

        for value in 1...10 {
            chain.produce(value)
        }

        #expect(chain.count == 3)
    }

    // MARK: - Cursors

    @Test
    func futureCursorOnlySeesElementsProducedAfterSubscribing() async {
        let chain = NodeChain<Int>(policy: .unbounded)
        let cursor = chain.futureCursor

        chain.send(1)

        try? await cursor.producer.wait()

        guard case .produced(let value) = cursor.snapshot.state else {
            Issue.record("Expected a produced value")
            return
        }

        #expect(value == 1)
    }

    @Test
    func currentCursorSeesTheLatestValueImmediately() {
        let chain = NodeChain(100, policy: .unbounded)

        guard case .produced(let value) = chain.currentCursor.snapshot.state else {
            Issue.record("Expected a produced value")
            return
        }

        #expect(value == 100)
    }

    @Test
    func replayCursorStartsAtTheOldestRetainedElement() {
        let chain = NodeChain<Int>(policy: .unbounded)

        chain.send(1)
        chain.send(2)

        guard case .produced(let value) = chain.makeReplayCursor().snapshot.state else {
            Issue.record("Expected a produced value")
            return
        }

        #expect(value == 1)
    }

    // MARK: - Completion

    @Test
    func completingTheChainEndsItAndSignalsTheTail() async {
        let chain = NodeChain<Int>(policy: .unbounded)
        let cursor = chain.futureCursor

        chain.finish()

        try? await cursor.producer.wait()

        guard case .completed = cursor.snapshot.state else {
            Issue.record("Expected the chain to be completed")
            return
        }
    }

    @Test
    func producingAfterCompletionIsANoOp() {
        let chain = NodeChain<Int>(policy: .unbounded)

        chain.finish()
        chain.send(1)

        #expect(chain.count == .zero)
    }

    // MARK: - Dropping

    /// A cell trimmed out of the window keeps its link forward, so a subscriber parked on it
    /// skips ahead instead of stalling.
    @Test
    func aDroppedCellStillLinksToItsSuccessor() {
        let chain = NodeChain<Int>(policy: .bufferingNewest(1))
        let cursor = chain.futureCursor

        chain.produce(1)
        chain.produce(2)

        let snapshot = cursor.snapshot

        guard case .dropped = snapshot.state else {
            Issue.record("Expected the first cell to have been dropped")
            return
        }

        guard case .produced(let value) = snapshot.next?.snapshot.state else {
            Issue.record("Expected the link forward to survive the drop")
            return
        }

        #expect(value == 2)
    }

    // MARK: - Until first iteration

    @Test
    func holdsEverythingBeforeTheFirstCursorIsCreated() {
        let chain = NodeChain<Int>(policy: .untilFirstIteration)

        for value in 1...50 {
            chain.send(value)
        }

        #expect(chain.holdsBuffer)
        #expect(chain.count == 50)
    }

    @Test
    func handsTheBufferOverToTheFirstCursor() {
        let chain = NodeChain<Int>(policy: .untilFirstIteration)

        chain.send(1)
        chain.send(2)

        let cursor = chain.makeReplayCursor()

        #expect(!chain.holdsBuffer)
        #expect(chain.count == .zero)

        // The cursor still points at the oldest element, so nothing was lost by releasing it.
        guard case .produced(let value) = cursor.snapshot.state else {
            Issue.record("Expected a produced value")
            return
        }

        #expect(value == 1)
    }

    @Test
    func stopsCountingOnceTheBufferHasBeenHandedOver() {
        let chain = NodeChain<Int>(policy: .untilFirstIteration)

        _ = chain.makeReplayCursor()

        for value in 1...10 {
            chain.send(value)
        }

        #expect(chain.count == .zero)
        #expect(!chain.holdsBuffer)
    }

    /// The property the whole mode exists for: once the buffer is released, a cell the
    /// consumer has moved past is retained by nothing and goes away immediately.
    @Test
    func advancingReleasesTheCellsLeftBehind() async {
        let chain = NodeChain<Int>(policy: .untilFirstIteration)

        chain.send(1)
        chain.send(2)

        weak var oldest: NodeSubject<Int>?
        var iterator: SubjectAsyncIterator<Int>

        do {
            let cursor = chain.makeReplayCursor()
            oldest = cursor
            iterator = .init(cursor)
        }

        // Still standing on it.
        #expect(oldest != nil)

        #expect(await iterator.next() == 1)

        // Moved past it, and the chain no longer holds a head, so nothing keeps it alive.
        #expect(oldest == nil)

        #expect(await iterator.next() == 2)
    }

    /// The same cell under `.unbounded` survives, because the chain keeps holding the head.
    @Test
    func unboundedKeepsTheCellsTheConsumerHasPassed() async {
        let chain = NodeChain<Int>(policy: .unbounded)

        chain.send(1)
        chain.send(2)

        weak var oldest: NodeSubject<Int>?
        var iterator: SubjectAsyncIterator<Int>

        do {
            let cursor = chain.makeReplayCursor()
            oldest = cursor
            iterator = .init(cursor)
        }

        #expect(await iterator.next() == 1)

        #expect(oldest != nil)
        #expect(chain.holdsBuffer)
    }

    // MARK: - Note
    //
    // A second `makeReplayCursor()` under `.untilFirstIteration` traps by design, so it has no
    // test here: Swift Testing has no way to assert a `preconditionFailure` without taking the
    // whole process down with it. The behaviour is documented on the policy and on the method.
}
