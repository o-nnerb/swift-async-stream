// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// Owns the chain of published elements and the window kept for consumers that fall behind.
///
/// The chain retains its own window, from ``head`` to the latest produced cell. Consumers hold
/// the cell they are parked on and nothing else, so trimming the window is what actually frees
/// memory: a discarded cell survives only while a consumer is still standing on it, and that
/// consumer is woken to move off immediately.
final class NodeChain<Element: Sendable>: @unchecked Sendable {

    // MARK: - Internal properties

    /// Subscription point for a subject that only broadcasts future elements.
    var futureCursor: NodeSubject<Element> {
        lock.withLock { _tail }
    }

    /// Subscription point for a subject that replays everything still inside the window.
    var replayCursor: NodeSubject<Element> {
        lock.withLock { _head }
    }

    /// Subscription point for a subject that replays its current element.
    var currentCursor: NodeSubject<Element> {
        lock.withLock { _latest ?? _tail }
    }

    /// Elements currently retained by the chain.
    var count: Int {
        lock.withLock { _count }
    }

    // MARK: - Private properties

    private let lock = Lock()
    private let policy: SubjectBufferingPolicy

    // MARK: - Unsafe properties

    private var _head: NodeSubject<Element>
    private var _latest: NodeSubject<Element>?
    private var _tail: NodeSubject<Element>
    private var _count = 0
    private var _isCompleted = false

    // MARK: - Inits

    init(policy: SubjectBufferingPolicy) {
        if case .bufferingNewest(let limit) = policy {
            precondition(limit >= 1, "bufferingNewest requires a limit of at least one element")
        }

        let node = NodeSubject<Element>()

        self.policy = policy
        _head = node
        _tail = node
    }

    convenience init(_ element: Element, policy: SubjectBufferingPolicy) {
        self.init(policy: policy)
        send(element)
    }

    deinit {
        finish()
    }

    // MARK: - Internal methods

    /// Appends an element and hands back the cells whose consumers have to be woken.
    ///
    /// - Important: Signal them only after releasing every lock the caller holds. Resuming a
    /// continuation inside a critical section invites priority inversion and reentrancy.
    /// - Returns: The cells to signal, in the order they should be woken.
    @discardableResult
    func produce(_ element: Element) -> [NodeSubject<Element>] {
        lock.withLock { () -> [NodeSubject<Element>] in
            guard !_isCompleted, let next = _tail.fill(element) else {
                return []
            }

            var signals = [_tail]

            _latest = _tail
            _tail = next
            _count += 1

            signals.append(contentsOf: _trim())
            return signals
        }
    }

    /// Ends the chain and hands back the cell whose consumers have to be woken.
    /// - Important: Same signalling rule as ``produce(_:)``.
    func complete() -> NodeSubject<Element>? {
        lock.withLock { () -> NodeSubject<Element>? in
            guard !_isCompleted else {
                return nil
            }

            _isCompleted = true
            _tail.complete()
            return _tail
        }
    }

    /// Appends an element and wakes its consumers.
    /// - Warning: Never call while holding a lock. Use ``produce(_:)`` instead and signal after
    /// releasing it.
    func send(_ element: Element) {
        produce(element).forEach { $0.producer.signal() }
    }

    /// Ends the chain and wakes its consumers.
    /// - Warning: Same rule as ``send(_:)``.
    func finish() {
        complete()?.producer.signal()
    }

    // MARK: - Unsafe methods

    /// Trims the window down to the policy limit.
    /// - Warning: Lockless. The caller must be holding ``lock``.
    /// - Returns: The discarded cells, which must be signalled so anyone parked on them skips
    /// forward instead of stalling.
    private func _trim() -> [NodeSubject<Element>] {
        guard case .bufferingNewest(let limit) = policy else {
            return []
        }

        var dropped = [NodeSubject<Element>]()

        // `limit` is at least one, so the latest cell is never reachable here: dropping stops
        // while at least one produced cell remains.
        while _count > limit, let next = _head.nextNode {
            _head.drop()
            dropped.append(_head)

            _head = next
            _count -= 1
        }

        return dropped
    }
}
