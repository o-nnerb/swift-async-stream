// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SwiftAsyncStream

/// A plain array backed sequence, used to validate `AnyAsyncSequence` against a source other
/// than the package's own subjects.
private struct NumbersSequence: AsyncSequence, Sendable {

    typealias Element = Int

    let numbers: [Int]

    struct AsyncIterator: AsyncIteratorProtocol, Sendable {

        var index = 0
        let numbers: [Int]

        mutating func next() async -> Int? {
            guard index < numbers.count else {
                return nil
            }

            defer { index += 1 }
            return numbers[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        .init(numbers: numbers)
    }
}

private struct ThrowingSequence: AsyncSequence, Sendable {

    typealias Element = Int

    struct Failure: Error {}

    struct AsyncIterator: AsyncIteratorProtocol, Sendable {

        mutating func next() async throws(Failure) -> Int? {
            if #available(iOS 18, tvOS 18, watchOS 11, macOS 15, visionOS 2, *) {
                throw Failure()
            } else {
                return nil
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        .init()
    }
}

struct AnyAsyncSequenceTests {

    @Test
    func erasesAnArbitrarySequence() async {
        let sequence = NumbersSequence(numbers: [1, 2, 3]).eraseToAnyAsyncSequence()

        var received = [Int]()
        for await value in sequence {
            received.append(value)
        }

        #expect(received == [1, 2, 3])
    }

    /// The bug this guards against: `makeAsyncIterator()` returning the same shared iterator
    /// on every call, so two consumers steal elements from each other instead of each seeing
    /// every one.
    @Test
    func eachMakeAsyncIteratorCallProducesAnIndependentIterator() async {
        let sequence = NumbersSequence(numbers: [1, 2, 3]).eraseToAnyAsyncSequence()

        let first = sequence.makeAsyncIterator()
        let second = sequence.makeAsyncIterator()

        #expect(await first.next() == 1)
        #expect(await second.next() == 1)
        #expect(await first.next() == 2)
        #expect(await second.next() == 2)
        #expect(await first.next() == 3)
        #expect(await second.next() == 3)
        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
    }

    @Test
    func aThrowingSourceEndsTheSequenceInsteadOfPropagatingTheError() async {
        let sequence = ThrowingSequence().eraseToAnyAsyncSequence()

        let iterator = sequence.makeAsyncIterator()
        let value = await iterator.next()

        #expect(value == nil)
    }
}
