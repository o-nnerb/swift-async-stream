// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

extension AsyncSequence where Element: Sendable, AsyncIterator: Sendable, Self: Sendable {

    /// Erases the concrete type of the async sequence to AnyAsyncSequence.
    /// - Returns: An AnyAsyncSequence that wraps this sequence.
    public func eraseToAnyAsyncSequence() -> AnyAsyncSequence<Element> {
        AnyAsyncSequence(self)
    }
}

/// A type-erased async sequence that can wrap any async sequence.
public struct AnyAsyncSequence<Element: Sendable>: AsyncSequence, Sendable {

    // MARK: - Inner types

    public typealias Element = Element
    public typealias AsyncIterator = AnyAsyncIterator

    /// A type-erased async iterator that can wrap any async iterator.
    ///
    /// - Warning: The iteration state lives in a reference box, so copies of the same value
    /// share their position. Obtain one instance per consumer through
    /// ``AnyAsyncSequence/makeAsyncIterator()``.
    public struct AnyAsyncIterator: AsyncIteratorProtocol, Sendable {

        // MARK: - Private properties

        private let nextClosure: @Sendable () async -> Element?

        // MARK: - Inits

        /// Creates a new AnyAsyncIterator from an existing iterator.
        /// - Parameter iterator: The iterator to wrap.
        public init<Iterator: AsyncIteratorProtocol>(
            _ iterator: Iterator
        ) where Iterator.Element == Element, Iterator: Sendable {
            let storage = InlineProperty(wrappedValue: iterator)
            nextClosure = { try? await storage.wrappedValue.next() }
        }

        // MARK: - Public methods

        /// Advances to the next element and returns it, or nil if no next element exists.
        /// - Returns: The next element if available, otherwise nil.
        public func next() async -> Element? {
            await nextClosure()
        }
    }

    // MARK: - Private properties

    private let iteratorFactory: @Sendable () -> AnyAsyncIterator

    // MARK: - Inits

    fileprivate init<Sequence: AsyncSequence>(
        _ sequence: Sequence
    ) where Sequence.Element == Element, Sequence: Sendable, Sequence.AsyncIterator: Sendable {
        iteratorFactory = {
            AnyAsyncIterator(sequence.makeAsyncIterator())
        }
    }

    // MARK: - Public methods

    /// Creates a new async iterator for this sequence.
    ///
    /// Each call produces an independent iterator, so multiple consumers of the same erased
    /// sequence receive the same elements instead of competing for them.
    ///
    /// - Returns: An AnyAsyncIterator that can iterate over the elements of this sequence.
    public func makeAsyncIterator() -> AsyncIterator {
        iteratorFactory()
    }
}
