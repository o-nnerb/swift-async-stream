import Foundation

public struct PassthroughSubject<Element: Sendable>: Sendable {

    private class Storage: @unchecked Sendable {

        private let lock = NSLock()

        private var _node = NodeSubject<Element>()

        init() {}

        func send(_ element: Element) {
            lock.withLock {
                let node = _node.produce(element)

                if let next = node.nextDataSource.next {
                    _node = next
                } else {
                    _node = node
                }
            }
        }

        func completed() {
            lock.withLock {
                _node.completed()
            }
        }

        func makeAsyncIterator() -> SubjectAsyncIterator<Element> {
            lock.withLock {
                .init(_node)
            }
        }

        deinit {
            _node.completed()
        }
    }

    private let storage = Storage()

    public init() {}

    public func send(_ element: Element) {
        storage.send(element)
    }

    public func completed() {
        storage.completed()
    }
}

extension PassthroughSubject: AsyncSequence {

    public typealias AsyncIterator = SubjectAsyncIterator<Element>

    public func makeAsyncIterator() -> AsyncIterator {
        storage.makeAsyncIterator()
    }
}
