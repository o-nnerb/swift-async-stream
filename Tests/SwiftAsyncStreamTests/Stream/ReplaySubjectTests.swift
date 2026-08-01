// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@_spi(Testing) @testable import SwiftAsyncStream

struct ReplaySubjectTests {

    // Every replayed element is already signalled, so `next()` returns without suspending and
    // these read the iterator directly. No tasks, no sleeps, no scheduling assumptions.

    // MARK: - Replay

    @Test
    func replaysEverythingToALateSubscriber() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        subject.send(1)
        subject.send(2)
        subject.send(3)

        var iterator = subject.makeAsyncIterator()

        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
    }

    @Test
    func continuesLiveAfterTheReplay() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        subject.send(1)

        var iterator = subject.makeAsyncIterator()
        #expect(await iterator.next() == 1)

        subject.send(2)
        #expect(await iterator.next() == 2)
    }

    @Test
    func deliversTheSameReplayToEveryNewSubscriber() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        subject.send(1)
        subject.send(2)

        var first = subject.makeAsyncIterator()
        var second = subject.makeAsyncIterator()

        #expect(await first.next() == 1)
        #expect(await second.next() == 1)
        #expect(await first.next() == 2)
        #expect(await second.next() == 2)
    }

    @Test
    func aSubscriberCreatedBeforeAnythingWasSentStillSeesEverything() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        var iterator = subject.makeAsyncIterator()

        subject.send(1)
        subject.send(2)

        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
    }

    // MARK: - Buffering policy

    @Test
    func replaysOnlyWhatFitsTheBuffer() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .bufferingNewest(2))

        subject.send(1)
        subject.send(2)
        subject.send(3)

        var iterator = subject.makeAsyncIterator()

        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
    }

    /// The buffer is shared, so a subscriber standing still while the window moves past it
    /// observes a gap rather than stalling on a discarded element.
    @Test
    func aSubscriberThatFallsBehindSkipsDiscardedElements() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .bufferingNewest(2))

        var iterator = subject.makeAsyncIterator()

        subject.send(1)
        subject.send(2)
        subject.send(3)
        subject.send(4)

        #expect(await iterator.next() == 3)
        #expect(await iterator.next() == 4)
    }

    /// The property that justifies the type having no default policy: bounded really is
    /// bounded, no matter how much goes through it.
    @Test
    func aBoundedBufferNeverGrowsPastItsLimit() {
        let subject = ReplaySubject<Int>(bufferingPolicy: .bufferingNewest(3))

        for value in 1...1000 {
            subject.send(value)
        }

        #expect(subject.bufferedCount == 3)
    }

    @Test
    func anUnboundedBufferKeepsEverything() {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        for value in 1...100 {
            subject.send(value)
        }

        #expect(subject.bufferedCount == 100)
    }

    // MARK: - Until first iteration

    @Test
    func untilFirstIterationBuffersEverythingBeforeAnyoneReads() {
        let subject = ReplaySubject<Int>(bufferingPolicy: .untilFirstIteration)

        for value in 1...100 {
            subject.send(value)
        }

        #expect(subject.holdsBuffer)
        #expect(subject.bufferedCount == 100)
    }

    @Test
    func untilFirstIterationStillReplaysEverythingToThatFirstReader() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .untilFirstIteration)

        subject.send(1)
        subject.send(2)
        subject.send(3)
        subject.completed()

        var received = [Int]()
        for await value in subject {
            received.append(value)
        }

        #expect(received == [1, 2, 3])
    }

    @Test
    func untilFirstIterationReleasesTheBufferOnceIterationStarts() {
        let subject = ReplaySubject<Int>(bufferingPolicy: .untilFirstIteration)

        subject.send(1)
        subject.send(2)

        #expect(subject.holdsBuffer)

        _ = subject.makeAsyncIterator()

        #expect(!subject.holdsBuffer)
        #expect(subject.bufferedCount == .zero)
    }

    /// The payoff: after handing the buffer over, publishing does not accumulate anything on
    /// the subject side, no matter how much goes through.
    @Test
    func untilFirstIterationStopsAccumulatingAfterTheHandover() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .untilFirstIteration)

        var iterator = subject.makeAsyncIterator()

        for value in 1...1000 {
            subject.send(value)
            #expect(await iterator.next() == value)
        }

        #expect(subject.bufferedCount == .zero)
    }

    @Test
    func untilFirstIterationKeepsWorkingLiveAfterTheHandover() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .untilFirstIteration)

        subject.send(1)

        var iterator = subject.makeAsyncIterator()
        #expect(await iterator.next() == 1)

        subject.send(2)
        #expect(await iterator.next() == 2)

        subject.completed()
        #expect(await iterator.next() == nil)
    }

    // A second `makeAsyncIterator()` under `.untilFirstIteration` traps by design. There is no
    // test for it: Swift Testing cannot assert a `preconditionFailure` without bringing the
    // whole process down. Wrappers that need to report the misuse instead use
    // `makeIteratorIfAvailable()`, which is covered below.

    // MARK: - Single use reporting

    @Test
    func makeIteratorIfAvailableReportsTheHandover() {
        let subject = ReplaySubject<Int>(bufferingPolicy: .untilFirstIteration)

        subject.send(1)

        #expect(subject.makeIteratorIfAvailable() != nil)
        #expect(subject.makeIteratorIfAvailable() == nil)
    }

    @Test
    func theFirstIteratorFromMakeIteratorIfAvailableStillReplaysEverything() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .untilFirstIteration)

        subject.send(1)
        subject.send(2)

        guard var iterator = subject.makeIteratorIfAvailable() else {
            Issue.record("Expected the buffer to still be available")
            return
        }

        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
    }

    /// Only `.untilFirstIteration` can ever run out. Every other policy keeps handing out
    /// iterators, so the optional variant behaves exactly like the plain one.
    @Test
    func makeIteratorIfAvailableNeverReportsAHandoverUnderOtherPolicies() {
        for policy in [SubjectBufferingPolicy.unbounded, .bufferingNewest(2)] {
            let subject = ReplaySubject<Int>(bufferingPolicy: policy)

            subject.send(1)

            #expect(subject.makeIteratorIfAvailable() != nil)
            #expect(subject.makeIteratorIfAvailable() != nil)
            #expect(subject.makeIteratorIfAvailable() != nil)
        }
    }

    // MARK: - Completion

    @Test
    func completingEndsTheSequenceAfterTheReplay() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        subject.send(1)
        subject.send(2)
        subject.completed()

        var iterator = subject.makeAsyncIterator()

        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == nil)
    }

    @Test
    func completingWithNothingProducedEndsImmediately() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        subject.completed()

        var iterator = subject.makeAsyncIterator()

        #expect(await iterator.next() == nil)
    }

    @Test
    func ignoresValuesSentAfterCompletion() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        subject.send(1)
        subject.completed()
        subject.send(2)

        var iterator = subject.makeAsyncIterator()

        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == nil)
    }

    // MARK: - Erasure

    @Test
    func erasesToAnyAsyncSequence() async {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        subject.send(1)
        subject.send(2)
        subject.completed()

        let erased = subject.eraseToAnyAsyncSequence()

        var received = [Int]()
        for await value in erased {
            received.append(value)
        }

        #expect(received == [1, 2])
    }

    // MARK: - Cancellation

    @Test
    func cancellingASubscriberEndsTheLoop() async throws {
        let subject = ReplaySubject<Int>(bufferingPolicy: .unbounded)

        let task = Task {
            for await value in subject {
                Issue.record("Should not receive \(value)")
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        task.cancel()

        try await withTaskTimeout(seconds: 1) {
            await task.value
        }
    }
}
