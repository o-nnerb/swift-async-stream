// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A single cell in the chain of published elements.
///
/// The cell owns the element it carries, the signal that releases consumers parked on it, and
/// a strong reference to its successor. Chain level concerns such as where the window starts
/// and how long it is belong to ``NodeChain``.
final class NodeSubject<Element: Sendable>: @unchecked Sendable {

    // MARK: - Inner types

    enum State: Sendable {
        /// Nothing produced yet. Consumers park here.
        case waiting
        /// Carries an element.
        case produced(Element)
        /// Carried an element that the buffering policy discarded. The link forward is kept so
        /// consumers parked here can skip ahead.
        case dropped
        /// The chain ended.
        case completed
    }

    /// An atomic view of the cell contents.
    ///
    /// State and successor change together, so reading them separately can expose a cell that
    /// already produced an element but does not yet advertise its successor.
    struct Snapshot: Sendable {
        let state: State
        let next: NodeSubject?
    }

    // MARK: - Internal properties

    let producer = AsyncSignal()

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(state: _state, next: _next)
        }
    }

    var nextNode: NodeSubject? {
        lock.withLock { _next }
    }

    // MARK: - Private properties

    private let lock = Lock()

    // MARK: - Unsafe properties

    private var _state: State = .waiting
    private var _next: NodeSubject?

    // MARK: - Inits

    init() {}

    deinit {
        producer.signal()

        // Releasing the head of a long chain would otherwise recurse through deinit, one frame
        // per cell, and overflow the stack. Unlink iteratively instead, stopping as soon as a
        // cell is still owned by someone else.
        var node = _next
        _next = nil

        while node != nil {
            guard isKnownUniquelyReferenced(&node) else {
                break
            }

            node = node?._detachNext()
        }
    }

    // MARK: - Internal methods

    /// Fills a waiting cell and links a fresh successor.
    /// - Returns: The new tail, or `nil` when the cell was no longer waiting.
    func fill(_ element: Element) -> NodeSubject? {
        lock.withLock { () -> NodeSubject? in
            guard case .waiting = _state else {
                return nil
            }

            let next = NodeSubject()
            _state = .produced(element)
            _next = next
            return next
        }
    }

    /// Discards the element while keeping the link forward.
    func drop() {
        lock.withLock {
            guard case .produced = _state else {
                return
            }

            _state = .dropped
        }
    }

    /// Ends the chain at this cell.
    func complete() {
        lock.withLock {
            _state = .completed
            _next = nil
        }
    }

    // MARK: - Unsafe methods

    /// Drops the link to the rest of the chain and returns it.
    /// - Warning: Lockless. Only valid while the cell is uniquely referenced.
    private func _detachNext() -> NodeSubject? {
        let next = _next
        _next = nil
        return next
    }
}
