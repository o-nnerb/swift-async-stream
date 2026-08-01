// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// An async iterator for subject-based publishers that yields elements as they are published.
public struct SubjectAsyncIterator<Element: Sendable>: AsyncIteratorProtocol, Sendable {

    // MARK: - Private properties

    private var node: NodeSubject<Element>?

    // MARK: - Inits

    init(_ node: NodeSubject<Element>) {
        self.node = node
    }

    // MARK: - Public methods

    /// Advances to the next element and returns it, or nil if no next element exists.
    ///
    /// Cancelling the current task terminates the sequence, so an ongoing `for await` loop
    /// exits instead of suspending forever.
    ///
    /// Elements discarded by the subject's buffering policy are skipped silently. A consumer
    /// that falls behind observes a gap, never a stall.
    ///
    /// - Returns: The next element if available, otherwise nil.
    public mutating func next() async -> Element? {
        while let node = self.node {
            do {
                try await node.producer.wait()
            } catch {
                self.node = nil
                return nil
            }

            let snapshot = node.snapshot

            switch snapshot.state {
            case .produced(let element):
                self.node = snapshot.next
                return element

            case .dropped:
                self.node = snapshot.next

            case .waiting, .completed:
                self.node = nil
                return nil
            }
        }

        return nil
    }
}
