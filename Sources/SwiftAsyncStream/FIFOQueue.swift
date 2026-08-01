// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A first in, first out queue with amortized constant time at both ends.
///
/// Removing from the front of an `Array` shifts every remaining element, and inserting at index
/// zero does the same, so a queue built out of either is quadratic in the number of items that
/// pass through it. Here the front is a cursor that only moves forward, and the backing storage
/// is rebuilt only once enough of it has gone dead.
///
/// Vacated slots are cleared rather than left behind, so a dequeued or removed element is
/// released immediately instead of lingering until the next compaction. That matters when the
/// elements are closures or class instances holding onto anything expensive.
///
/// ```swift
/// var queue = FIFOQueue<Int>()
///
/// queue.append(1)
/// queue.append(2)
///
/// queue.popFirst()   // 1
/// queue.popFirst()   // 2
/// queue.popFirst()   // nil
/// ```
///
/// - Note: This is a value type with no synchronization of its own. Guard it the same way you
/// would guard an `Array`.
public struct FIFOQueue<Element> {

    // MARK: - Public properties

    /// The number of elements currently in the queue.
    public private(set) var count = 0

    /// Whether the queue holds no elements.
    public var isEmpty: Bool {
        count == .zero
    }

    /// Every queued element, oldest first.
    ///
    /// - Complexity: O(*n*). Meant for inspection and debugging rather than for iteration in a
    /// hot path.
    public var elements: [Element] {
        storage[head...].compactMap { $0 }
    }

    // MARK: - Private properties

    /// How wide the live span has to be before rebuilding is worth the copy.
    private static var compactionThreshold: Int { 32 }

    // MARK: - Unsafe properties

    private var storage = [Element?]()
    private var head = 0

    // MARK: - Inits

    /// Creates an empty queue.
    public init() {}

    // MARK: - Public methods

    /// Adds an element to the back of the queue.
    /// - Complexity: O(1), amortized.
    public mutating func append(_ element: Element) {
        storage.append(element)
        count += 1
    }

    /// Removes and returns the oldest element.
    /// - Returns: The oldest element, or `nil` when the queue is empty.
    /// - Complexity: O(1), amortized.
    public mutating func popFirst() -> Element? {
        while head < storage.count {
            let element = storage[head]

            storage[head] = nil
            head += 1

            guard let element else {
                // A slot vacated by `removeAll(where:)`.
                continue
            }

            count -= 1
            compactIfNeeded()
            return element
        }

        compactIfNeeded()
        return nil
    }

    /// Removes every element matching the predicate, keeping the order of the rest.
    /// - Parameter shouldRemove: Returns `true` for elements to drop.
    /// - Complexity: O(*n*).
    public mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        for index in head..<storage.count {
            guard let element = storage[index], shouldRemove(element) else {
                continue
            }

            storage[index] = nil
            count -= 1
        }

        compactIfNeeded()
    }

    /// Empties the queue and returns everything that was in it, oldest first.
    /// - Returns: The removed elements.
    /// - Complexity: O(*n*).
    public mutating func drain() -> [Element] {
        let elements = self.elements

        storage.removeAll(keepingCapacity: true)
        head = .zero
        count = .zero

        return elements
    }

    // MARK: - Private methods

    private mutating func compactIfNeeded() {
        guard head < storage.count else {
            // Fully drained, which is the common case for an uncontended queue.
            storage.removeAll(keepingCapacity: true)
            head = .zero
            return
        }

        let span = storage.count - head

        guard span > Self.compactionThreshold, count * 2 <= span else {
            return
        }

        var compacted = [Element?]()
        compacted.reserveCapacity(count)

        for index in head..<storage.count {
            guard let element = storage[index] else {
                continue
            }

            compacted.append(element)
        }

        storage = compacted
        head = .zero
    }
}

// MARK: - Sendable

extension FIFOQueue: Sendable where Element: Sendable {}
