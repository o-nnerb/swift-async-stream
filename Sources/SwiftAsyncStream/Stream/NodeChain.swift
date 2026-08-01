// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// Owns the chain of published elements and the window kept for consumers that fall behind.
///
/// The chain retains its own window, from ``_head`` to the latest produced cell. Consumers hold
/// the cell they are parked on and nothing else, so what the chain holds is what decides the
/// floor on memory: while it holds a head, nothing behind that head can ever be released.
final class NodeChain<Element: Sendable>: @unchecked Sendable {

    // MARK: - Internal properties

    /// Subscription point for a subject that only broadcasts future elements.
    var futureCursor: NodeSubject<Element> {
        lock.withLock { _tail }
    }

    /// Subscription point for a subject that replays its current element.
    var currentCursor: NodeSubject<Element> {
        lock.withLock { _latest ?? _tail }
    }

    /// Elements currently retained by the chain.
    ///
    /// Zero once the head has been handed over: from that point the chain holds no window, and
    /// what stays alive is decided entirely by where the consumers are standing.
    var count: Int {
        lock.withLock { _count }
    }

    /// Whether the chain still holds a replayable window.
    var holdsBuffer: Bool {
        lock.withLock { _head != nil }
    }

    // MARK: - Private properties

    private let lock = Lock()
    private let policy: SubjectBufferingPolicy

    // MARK: - Unsafe properties

    // Optional because `.untilFirstIteration` gives it up. Everything behind the head is
    // retained through it, so releasing it is what actually frees memory.
    private var _head: NodeSubject<Element>?

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

    /// Subscription point for a subject that replays everything still inside the window.
    ///
    /// Under ``SubjectBufferingPolicy/untilFirstIteration`` this hands the window over and the
    /// chain stops holding it, which makes the call single use.
    ///
    /// - Returns: The oldest retained cell, or `nil` when the window has already been handed
    /// over. Never the tail: giving a second reader whatever happened to survive would be a
    /// partial result that changes with how far the first reader got.
    func makeReplayCursorIfAvailable() -> NodeSubject<Element>? {
        lock.withLock { () -> NodeSubject<Element>? in
            guard let head = _head else {
                return nil
            }

            if case .untilFirstIteration = policy {
                _head = nil
                _count = .zero
            }

            return head
        }
    }

    /// Same as ``makeReplayCursorIfAvailable()``, for callers with no way to report the misuse.
    /// - Warning: Traps when the window has already been handed over.
    func makeReplayCursor() -> NodeSubject<Element> {
        guard let cursor = makeReplayCursorIfAvailable() else {
            preconditionFailure(
                """
                This subject buffers only until its first iteration and has already been \
                iterated. Create one subject per consumer, or use a policy that keeps the \
                buffer for every subscriber.
                """
            )
        }

        return cursor
    }

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

            // Only counts what the chain itself is holding. Once the head is gone the chain
            // retains no window, so there is nothing to count and nothing to trim.
            if _head != nil {
                _count += 1
                signals.append(contentsOf: _trim())
            }

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
        while _count > limit, let head = _head, let next = head.nextNode {
            head.drop()
            dropped.append(head)

            _head = next
            _count -= 1
        }

        return dropped
    }
}
