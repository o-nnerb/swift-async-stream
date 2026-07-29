// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A FIFO queue backed by an array and a read cursor.
///
/// Removing from the front of an `Array` shifts every remaining element, and inserting at index
/// zero does the same, so a queue built out of either is quadratic in the number of items that
/// pass through it. Here the front is a cursor that only moves forward, and the backing storage
/// is rebuilt only once enough of it has gone dead, which keeps every operation amortized
/// constant.
///
/// Vacated slots are cleared rather than left behind, so a dequeued or removed element is
/// released immediately instead of waiting for the next compaction.
struct FIFOQueue<Element> {

    // MARK: - Internal properties

    /// Elements currently in the queue.
    private(set) var count = 0

    var isEmpty: Bool {
        count == .zero
    }

    /// Every queued element, oldest first.
    var elements: [Element] {
        storage[head...].compactMap { $0 }
    }

    // MARK: - Private properties

    /// How wide the live span has to be before rebuilding is worth the copy.
    private static var compactionThreshold: Int { 32 }

    // MARK: - Unsafe properties

    private var storage = [Element?]()
    private var head = 0

    // MARK: - Inits

    init() {}

    // MARK: - Internal methods

    /// Adds an element to the back of the queue.
    mutating func append(_ element: Element) {
        storage.append(element)
        count += 1
    }

    /// Removes and returns the oldest element.
    mutating func popFirst() -> Element? {
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
    mutating func removeAll(where shouldRemove: (Element) -> Bool) {
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
    mutating func drain() -> [Element] {
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
