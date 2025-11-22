import Foundation

extension AsyncSequence where Element: Sendable, AsyncIterator: Sendable, Self: Sendable {

    public func eraseToAnyAsyncSequence() -> AnyAsyncSequence<Element> {
        AnyAsyncSequence(self)
    }
}

public struct AnyAsyncSequence<Element: Sendable>: AsyncSequence, Sendable {

    public typealias Element = Element
    public typealias AsyncIterator = AnyAsyncIterator

    public struct AnyAsyncIterator: AsyncIteratorProtocol, Sendable {

        private let nextClosure: @Sendable () async -> Element?

        public init<Iterator: AsyncIteratorProtocol>(_ iterator: Iterator) where Iterator.Element == Element, Iterator: Sendable {
            let iterator = InlineProperty(wrappedValue: iterator)
            nextClosure = { try? await iterator.wrappedValue.next() }
        }

        public func next() async -> Element? {
            await nextClosure()
        }
    }

    private let iterator: AnyAsyncIterator

    fileprivate init<Sequence: AsyncSequence>(_ sequence: Sequence) where Sequence.Element == Element, Sequence: Sendable, Sequence.AsyncIterator: Sendable {
        iterator = AnyAsyncIterator(sequence.makeAsyncIterator())
    }

    public func makeAsyncIterator() -> AsyncIterator {
        iterator
    }
}
