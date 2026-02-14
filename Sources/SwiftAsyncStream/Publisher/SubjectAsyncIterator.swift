// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An async iterator for subject-based publishers that yields elements as they are published.
public struct SubjectAsyncIterator<Element: Sendable>: AsyncIteratorProtocol, Sendable {

    private var node: NodeSubject<Element>?

    init(_ node: NodeSubject<Element>) {
        self.node = node
    }

    /// Advances to the next element and returns it, or nil if no next element exists.
    /// - Returns: The next element if available, otherwise nil.
    public mutating func next() async -> Element? {
        guard let node else {
            return nil
        }

        await node.producer.wait()

        self.node = node.nextDataSource.next

        switch node.stateDataSource.state {
        case .produced(let element):
            return element
        case .waiting, .completed:
            return nil
        }
    }
}
