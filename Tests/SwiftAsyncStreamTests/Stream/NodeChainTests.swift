// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import SwiftAsyncStream

struct NodeChainTests {

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
}
