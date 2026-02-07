// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension AsyncSequence where Element: Sendable, AsyncIterator: Sendable, Self: Sendable {

    /// Erases the concrete type of the async sequence to AnyAsyncSequence.
    /// - Returns: An AnyAsyncSequence that wraps this sequence.
    public func eraseToAnyAsyncSequence() -> AnyAsyncSequence<Element> {
        AnyAsyncSequence(self)
    }
}

/// A type-erased async sequence that can wrap any async sequence.
public struct AnyAsyncSequence<Element: Sendable>: AsyncSequence, Sendable {

    public typealias Element = Element
    public typealias AsyncIterator = AnyAsyncIterator

    /// A type-erased async iterator that can wrap any async iterator.
    public struct AnyAsyncIterator: AsyncIteratorProtocol, Sendable {

        private let nextClosure: @Sendable () async -> Element?

        /// Creates a new AnyAsyncIterator from an existing iterator.
        /// - Parameter iterator: The iterator to wrap.
        public init<Iterator: AsyncIteratorProtocol>(_ iterator: Iterator) where Iterator.Element == Element, Iterator: Sendable {
            let iterator = InlineProperty(wrappedValue: iterator)
            nextClosure = { try? await iterator.wrappedValue.next() }
        }

        /// Advances to the next element and returns it, or nil if no next element exists.
        /// - Returns: The next element if available, otherwise nil.
        public func next() async -> Element? {
            await nextClosure()
        }
    }

    private let iterator: AnyAsyncIterator

    fileprivate init<Sequence: AsyncSequence>(_ sequence: Sequence) where Sequence.Element == Element, Sequence: Sendable, Sequence.AsyncIterator: Sendable {
        iterator = AnyAsyncIterator(sequence.makeAsyncIterator())
    }

    /// Creates an async iterator for this sequence.
    /// - Returns: An AnyAsyncIterator that can iterate over the elements of this sequence.
    public func makeAsyncIterator() -> AsyncIterator {
        iterator
    }
}
