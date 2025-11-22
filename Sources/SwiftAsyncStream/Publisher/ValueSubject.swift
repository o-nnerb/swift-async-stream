import Foundation

public struct ValueSubject<Element: Sendable>: Sendable {

    private class Storage: @unchecked Sendable {

        var value: Element {
            get {
                lock.withLock {
                    guard case .produced(let element) = _node.stateDataSource.state else {
                        fatalError("No value of type \(Element.self) produced")
                    }

                    return element
                }
            }
            set {
                lock.withLock {
                    _node = _node.produce(newValue)
                }
            }
        }

        private let lock = NSLock()

        private var _node: NodeSubject<Element>

        init(_ element: Element) {
            _node = .init(element)
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

    public var value: Element {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    private let storage: Storage

    public init(_ element: Element) {
        storage = .init(element)
    }
}

extension ValueSubject: AsyncSequence {

    public typealias AsyncIterator = SubjectAsyncIterator<Element>

    public func makeAsyncIterator() -> AsyncIterator {
        storage.makeAsyncIterator()
    }
}
