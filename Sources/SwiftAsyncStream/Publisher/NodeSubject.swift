import Foundation

final class NodeSubject<Element: Sendable>: Sendable {

    enum State: Sendable {
        case produced(Element)
        case waiting
    }

    final class StateDataSource: @unchecked Sendable {

        var state: State {
            get { lock.withLock { _state }}
            set { lock.withLock { _state = newValue }}
        }

        private let lock = NSLock()

        private var _state: State

        init(_ state: State) {
            _state = state
        }
    }

    final class NextDataSource: @unchecked Sendable {

        var next: NodeSubject? {
            get { lock.withLock { _next }}
            set { lock.withLock { _next = newValue }}
        }

        private let lock = NSLock()

        private var _next: NodeSubject?

        init(_ node: NodeSubject? = nil) {
            _next = node
        }
    }

    let stateDataSource: StateDataSource
    let nextDataSource: NextDataSource

    let producer: AsyncSignal

    init() {
        stateDataSource = .init(.waiting)
        nextDataSource = .init()
        producer = .init()
    }

    init(_ element: Element) {
        stateDataSource = .init(.produced(element))
        nextDataSource = .init(.init())
        producer = .init(true)
    }

    func produce(_ element: Element) -> NodeSubject {
        var topMostNodeReference = self

        while let next = topMostNodeReference.nextDataSource.next {
            topMostNodeReference = next
        }

        topMostNodeReference.stateDataSource.state = .produced(element)
        if topMostNodeReference.nextDataSource.next == nil {
            topMostNodeReference.nextDataSource.next = NodeSubject()
        }
        topMostNodeReference.producer.signal()
        return topMostNodeReference
    }

    func completed() {
        producer.signal()
    }

    deinit {
        producer.signal()
    }
}
