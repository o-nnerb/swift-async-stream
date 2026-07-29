// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A publisher that broadcasts elements to multiple subscribers and replays what it still
/// holds to each new one.
///
/// A subscriber joining late receives everything currently inside the buffer, oldest first,
/// and then continues live. `.bufferingNewest(n)` therefore means "replay the last n", the
/// same contract as a bounded replay subject in a reactive framework.
///
/// - Important: `bufferingPolicy` has no default on purpose. The other subjects only retain
/// elements while a subscriber is behind, so a keeping up reader lets them go. This one is
/// obliged to hold its window whether anyone is reading or not, which makes `.unbounded` a
/// commitment to grow for the lifetime of the subject rather than a mild default.
public struct ReplaySubject<Element: Sendable>: Sendable {

    // MARK: - Private properties

    private let chain: NodeChain<Element>

    // MARK: - Inits

    /// Creates a new ReplaySubject instance.
    /// - Parameter bufferingPolicy: How many published elements are kept and replayed.
    /// `.bufferingNewest(n)` replays the last `n`. `.unbounded` replays everything and never
    /// releases it.
    public init(bufferingPolicy: SubjectBufferingPolicy) {
        chain = .init(policy: bufferingPolicy)
    }

    // MARK: - Public methods

    /// Publishes a new element to all subscribers and adds it to the replay buffer.
    /// - Parameter element: The element to publish.
    public func send(_ element: Element) {
        chain.send(element)
    }

    /// Signals that the publisher has finished publishing values.
    ///
    /// Subscribers that join afterwards still receive the replay, then the termination.
    public func completed() {
        chain.finish()
    }
}

// MARK: - AsyncSequence

extension ReplaySubject: AsyncSequence {

    public typealias AsyncIterator = SubjectAsyncIterator<Element>

    public func makeAsyncIterator() -> AsyncIterator {
        .init(chain.replayCursor)
    }
}

// MARK: - Testing

@_spi(Testing)
public extension ReplaySubject {

    /// Elements currently held in the replay buffer.
    var bufferedCount: Int {
        chain.count
    }
}
