// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A property wrapper giving a value reference semantics behind a lock.
///
/// Reads and writes are individually safe. They are **not** composable: `wrappedValue += 1`
/// is a read, a modify and a write, so concurrent callers lose updates. Use
/// ``withValue(_:)`` whenever the new value depends on the old one.
@propertyWrapper
public struct InlineProperty<Value> {

    // MARK: - Inner types

    private final class Storage: @unchecked Sendable {

        // MARK: - Internal properties

        var wrappedValue: Value {
            get { lock.withLock { _wrappedValue } }
            set { lock.withLock { _wrappedValue = newValue } }
        }

        // MARK: - Private properties

        private let lock = Lock()

        // MARK: - Unsafe properties

        private var _wrappedValue: Value

        // MARK: - Inits

        init(wrappedValue: Value) {
            _wrappedValue = wrappedValue
        }

        // MARK: - Internal methods

        func withValue<Result, Failure: Error>(
            _ body: (inout Value) throws(Failure) -> Result
        ) throws(Failure) -> Result {
            try lock.withLock { () throws(Failure) -> Result in
                try body(&_wrappedValue)
            }
        }
    }

    // MARK: - Public properties

    public var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    // MARK: - Private properties

    private let storage: Storage

    // MARK: - Inits

    public init(wrappedValue: Value) {
        storage = .init(wrappedValue: wrappedValue)
    }

    // MARK: - Public methods

    /// Reads and writes the value in a single critical section.
    ///
    /// ```swift
    /// counter.withValue { $0 += 1 }
    /// ```
    ///
    /// - Warning: The closure runs while the lock is held. Do not touch this property from
    /// inside it, and do not suspend: the lock is not reentrant.
    @discardableResult
    public func withValue<Result, Failure: Error>(
        _ body: (inout Value) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try storage.withValue(body)
    }
}

// MARK: - Sendable

// Conditional on purpose. An unconditional conformance, with the storage marked
// `@unchecked Sendable`, would let a non-Sendable value cross an isolation boundary with the
// compiler's approval.
extension InlineProperty: Sendable where Value: Sendable {}

// MARK: - Equatable

extension InlineProperty: Equatable where Value: Equatable {

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}

// MARK: - Hashable

extension InlineProperty: Hashable where Value: Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(wrappedValue)
    }
}
