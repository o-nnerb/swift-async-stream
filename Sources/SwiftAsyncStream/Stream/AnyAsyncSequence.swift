// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

extension AsyncSequence where Element: Sendable, Self: Sendable, AsyncIterator: SendableMetatype {

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
        public init<Iterator: AsyncIteratorProtocol & SendableMetatype>(
            _ iterator: Iterator
        ) where Iterator.Element == Element {
            let box = IteratorBox(iterator)
            nextClosure = { await box.next() }
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
    ) where Sequence.Element == Element, Sequence: Sendable, Sequence.AsyncIterator: SendableMetatype {
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

// MARK: - IteratorBox

/// Boxes a wrapped iterator behind a lock so it can be driven from the `@Sendable` closure
/// that backs ``AnyAsyncSequence/AnyAsyncIterator``, regardless of whether `Iterator` itself
/// conforms to `Sendable`.
///
/// `AsyncIteratorProtocol.next()` is only ever called serially by a single consumer, never
/// concurrently, so the lock only has to guard visibility across the thread hops an `await`
/// can introduce between the get and the set below, not real concurrent mutation. That is
/// weaker than what `Sendable` demands, which is why the conformance is `@unchecked` and, unlike
/// ``InlineProperty``, unconditional on `Iterator`. Only `SendableMetatype` is required (every
/// concrete type gets that for free unless it opts out), not `Sendable` itself: third-party
/// async sequences, including Apple's own swift-async-algorithms, routinely ship public
/// iterator types without an explicit `Sendable` conformance even when their state would
/// trivially allow it, so demanding `Sendable` here would make erasing those sequences
/// impossible.
private final class IteratorBox<Iterator: AsyncIteratorProtocol & SendableMetatype>: @unchecked Sendable {

    // MARK: - Private properties

    private let lock = Lock()
    private var iterator: Iterator

    // MARK: - Inits

    init(_ iterator: Iterator) {
        self.iterator = iterator
    }

    // MARK: - Internal methods

    func next() async -> Iterator.Element? {
        var current = lock.withLock { iterator }
        defer { lock.withLock { iterator = current } }
        return try? await current.next()
    }
}
