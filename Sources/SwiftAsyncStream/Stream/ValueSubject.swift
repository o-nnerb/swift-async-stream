// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A publisher that broadcasts elements to multiple subscribers and maintains a current value.
/// Each new subscriber immediately receives the current value upon subscription.
public struct ValueSubject<Element: Sendable>: Sendable {

    // MARK: - Inner types

    private final class Storage: @unchecked Sendable {

        // MARK: - Internal properties

        let chain: NodeChain<Element>

        var value: Element {
            get {
                lock.withLock { _value }
            }
            set {
                // Assigning and appending happen together, so two concurrent writers can never
                // leave `value` disagreeing with the order the stream published. Signalling is
                // deliberately left outside the critical section.
                let signals = lock.withLock { () -> [NodeSubject<Element>] in
                    _value = newValue
                    return chain.produce(newValue)
                }

                signals.forEach { $0.producer.signal() }
            }
        }

        // MARK: - Private properties

        private let lock = Lock()

        // MARK: - Unsafe properties

        // The current value is kept alongside the chain rather than read back out of it, so
        // reading it never depends on the state the chain happens to be in.
        private var _value: Element

        // MARK: - Inits

        init(_ element: Element, policy: SubjectBufferingPolicy) {
            _value = element
            chain = .init(element, policy: policy)
        }
    }

    // MARK: - Public properties

    /// The current value of the subject.
    public var value: Element {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    // MARK: - Private properties

    private let storage: Storage

    // MARK: - Inits

    /// Creates a new ValueSubject with an initial value.
    /// - Parameters:
    ///   - element: The initial value for the subject.
    ///   - bufferingPolicy: How many published elements are kept for subscribers that fall
    ///   behind. `.bufferingNewest(1)` turns the subject into a conflating one, where a slow
    ///   subscriber always jumps straight to the latest value.
    public init(_ element: Element, bufferingPolicy: SubjectBufferingPolicy = .unbounded) {
        precondition(
            bufferingPolicy != .untilFirstIteration,
            """
            ValueSubject cannot buffer until its first iteration: subscribers join at the \
            latest element, so the head is never handed to anyone and the buffer would be held \
            forever. Use ReplaySubject for that policy.
            """
        )

        storage = .init(element, policy: bufferingPolicy)
    }
}

// MARK: - AsyncSequence

extension ValueSubject: AsyncSequence {

    public typealias AsyncIterator = SubjectAsyncIterator<Element>

    public func makeAsyncIterator() -> AsyncIterator {
        .init(storage.chain.currentCursor)
    }
}
