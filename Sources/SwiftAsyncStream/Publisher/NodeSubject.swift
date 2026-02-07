// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import Foundation

final class NodeSubject<Element: Sendable>: Sendable {

    enum State: Sendable {
        case produced(Element)
        case waiting
        case completed
    }

    final class StateDataSource: @unchecked Sendable {

        var state: State {
            get { lock.withLock { _state }}
            set { lock.withLock { _state = newValue }}
        }

        private let lock = Lock()

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

        private let lock = Lock()

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
        let topMostNodeReference = self.topMostNodeReference()

        if case .completed = topMostNodeReference.stateDataSource.state {
            return topMostNodeReference
        }

        topMostNodeReference.stateDataSource.state = .produced(element)
        if topMostNodeReference.nextDataSource.next == nil {
            topMostNodeReference.nextDataSource.next = NodeSubject()
        }
        topMostNodeReference.producer.signal()
        return topMostNodeReference
    }

    func completed() -> NodeSubject {
        let topMostNodeReference = self.topMostNodeReference()
        topMostNodeReference.stateDataSource.state = .completed
        topMostNodeReference.nextDataSource.next = nil
        topMostNodeReference.producer.signal()
        return topMostNodeReference
    }

    private func topMostNodeReference() -> NodeSubject<Element> {
        var topMostNodeReference = self

        while let next = topMostNodeReference.nextDataSource.next {
            topMostNodeReference = next
        }

        return topMostNodeReference
    }

    deinit {
        producer.signal()
    }
}
