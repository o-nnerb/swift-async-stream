import Foundation

/// A publisher that broadcasts elements to multiple subscribers and maintains a current value.
/// Each new subscriber immediately receives the current value upon subscription.
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
            _node = _node.completed()
        }
    }

    /// The current value of the subject.
    public var value: Element {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    private let storage: Storage

    /// Creates a new ValueSubject with an initial value.
    /// - Parameter element: The initial value for the subject.
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
