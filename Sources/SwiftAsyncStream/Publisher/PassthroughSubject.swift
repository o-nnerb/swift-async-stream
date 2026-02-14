// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A publisher that broadcasts elements to multiple subscribers.
/// It doesn't store any values, so subscribers only receive elements published after subscription.
public struct PassthroughSubject<Element: Sendable>: Sendable {

    private class Storage: @unchecked Sendable {

        private let lock = Lock()

        private var _node = NodeSubject<Element>()

        init() {}

        deinit {
            _update(_node.completed())
        }

        func send(_ element: Element) {
            lock.withLock {
               _update(_node.produce(element))
            }
        }

        func completed() {
            lock.withLock {
                _update(_node.completed())
            }
        }

        func makeAsyncIterator() -> SubjectAsyncIterator<Element> {
            lock.withLock {
                .init(_node)
            }
        }

        private func _update(_ node: NodeSubject<Element>) {
            if let next = node.nextDataSource.next {
                _node = next
            } else {
                _node = node
            }
        }
    }

    private let storage = Storage()

    /// Creates a new PassthroughSubject instance.
    public init() {}

    /// Publishes a new element to all subscribers.
    /// - Parameter element: The element to publish.
    public func send(_ element: Element) {
        storage.send(element)
    }

    /// Signals that the publisher has finished publishing values.
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
