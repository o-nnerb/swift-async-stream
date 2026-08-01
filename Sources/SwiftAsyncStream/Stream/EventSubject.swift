// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A publisher that broadcasts elements to multiple subscribers.
/// It doesn't store any values, so subscribers only receive elements published after subscription.
public struct EventSubject<Element: Sendable>: Sendable {

    // MARK: - Private properties

    private let chain: NodeChain<Element>

    // MARK: - Inits

    /// Creates a new EventSubject instance.
    /// - Parameter bufferingPolicy: How many published elements are kept for subscribers that
    /// fall behind. Defaults to `.unbounded`, which lets a stalled subscriber pin every element
    /// published since it stalled.
    public init(bufferingPolicy: SubjectBufferingPolicy = .unbounded) {
        precondition(
            bufferingPolicy != .untilFirstIteration,
            """
            EventSubject cannot buffer until its first iteration: subscribers join at the tail, \
            so the head is never handed to anyone and the buffer would be held forever. Use \
            ReplaySubject for that policy.
            """
        )

        chain = .init(policy: bufferingPolicy)
    }

    // MARK: - Public methods

    /// Publishes a new element to all subscribers.
    /// - Parameter element: The element to publish.
    public func send(_ element: Element) {
        chain.send(element)
    }

    /// Signals that the publisher has finished publishing values.
    public func completed() {
        chain.finish()
    }
}

// MARK: - AsyncSequence

extension EventSubject: AsyncSequence {

    public typealias AsyncIterator = SubjectAsyncIterator<Element>

    public func makeAsyncIterator() -> AsyncIterator {
        .init(chain.futureCursor)
    }
}
