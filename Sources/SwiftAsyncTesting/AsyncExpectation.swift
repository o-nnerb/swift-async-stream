// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

@_exported import SwiftAsyncStream

// Not every Swift SDK ships a Testing module — the official static Android SDK
// bundle, for one, only carries production-oriented modules (Foundation,
// Dispatch, Observation, ...) and omits Testing/XCTest entirely from its
// swift_static-*/android resource directory. This target only has meaning in
// a test context, so it degrades to an empty module rather than breaking the
// build for platforms without Testing.
#if canImport(Testing)
import Testing

// Checked independently of Darwin: some Darwin-based toolchains (e.g. a
// Tuist-generated project) can drop XCTest from the module search path
// while Swift Testing stays available.
#if canImport(XCTest)
import XCTest
#endif

/// An expectation for use in asynchronous testing.
/// It allows tests to wait for specific conditions to be met before continuing.
public struct AsyncExpectation: Sendable {

    // MARK: - Inner types

    private final class Storage: @unchecked Sendable {

        /// The outcome of a single `fulfill()`, decided in one critical section.
        ///
        /// Counting and deciding have to happen together. Reading the counter back after
        /// incrementing it lets a concurrent call slip in between, which either loses an
        /// increment or skips past the exact value the wait is keyed on. Both leave the
        /// expectation waiting forever.
        struct Outcome {
            let didSatisfy: Bool
            let didOverFulfill: Bool
            let count: Int
            let expected: Int
        }

        var fulfillmentCount: Int {
            lock.withLock { _fulfillmentCount }
        }

        var expectedFulfillmentCount: Int {
            lock.withLock { _expectedFulfillmentCount }
        }

        var assertForOverFulfill: Bool {
            get { lock.withLock { _assertForOverFulfill } }
            set { lock.withLock { _assertForOverFulfill = newValue } }
        }

        var isInverted: Bool {
            get { lock.withLock { _isInverted } }
            set { lock.withLock { _isInverted = newValue } }
        }

        private let lock = Lock()

        private var _fulfillmentCount: Int = .zero
        private var _expectedFulfillmentCount: Int = 1
        private var _assertForOverFulfill: Bool = true
        private var _isInverted: Bool = false

        func setExpectedFulfillmentCount(_ newValue: Int) {
            lock.withLock {
                precondition(
                    newValue >= _fulfillmentCount,
                    "Expected fulfillment count cannot be lower than the current count"
                )

                _expectedFulfillmentCount = newValue
            }
        }

        func fulfill() -> Outcome {
            lock.withLock {
                _fulfillmentCount += 1

                return Outcome(
                    didSatisfy: _fulfillmentCount == _expectedFulfillmentCount,
                    didOverFulfill: _fulfillmentCount > _expectedFulfillmentCount && _assertForOverFulfill,
                    count: _fulfillmentCount,
                    expected: _expectedFulfillmentCount
                )
            }
        }
    }

    // MARK: - Public properties

    /// The number of times this expectation is expected to be fulfilled.
    public var expectedFulfillmentCount: Int {
        get { storage.expectedFulfillmentCount }
        nonmutating set { storage.setExpectedFulfillmentCount(newValue) }
    }

    /// Whether to assert when the expectation is fulfilled more times than expected.
    public var assertForOverFulfill: Bool {
        get { storage.assertForOverFulfill }
        nonmutating set { storage.assertForOverFulfill = newValue }
    }

    /// Whether this expectation is inverted (should fail if fulfilled).
    public var isInverted: Bool {
        get { storage.isInverted }
        nonmutating set { storage.isInverted = newValue }
    }

    // MARK: - Internal properties

    var fulfillmentCount: Int {
        storage.fulfillmentCount
    }

    let description: String

    var sourceLocation: SourceLocation {
        .init(fileID: fileID, filePath: filePath, line: line, column: column)
    }

    // MARK: - Private properties

    private let signal = AsyncSignal()

    private let storage = Storage()

    private let fileID: String
    private let filePath: String
    private let line: Int
    private let column: Int

    // MARK: - Inits

    /// Creates a new AsyncExpectation instance.
    /// - Parameters:
    ///   - description: A description of the expectation.
    ///   - fileID: The file ID where the expectation was created.
    ///   - filePath: The file path where the expectation was created.
    ///   - line: The line number where the expectation was created.
    ///   - column: The column number where the expectation was created.
    public init(
        description: String = #function,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        self.description = description
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
    }

    // MARK: - Public methods

    /// Marks the expectation as fulfilled.
    public func fulfill() {
        guard !storage.isInverted else {
            record("Inverted expectation was fulfilled, which is a failure.")

            // Releasing the wait as well. The failure is already recorded, so holding the
            // suite for the rest of the timeout only delays a result that is already known.
            signal.signal()
            return
        }

        let outcome = storage.fulfill()

        if outcome.didSatisfy {
            return signal.signal()
        }

        guard outcome.didOverFulfill else {
            return
        }

        record("Expected fulfill count to be \(outcome.expected), got \(outcome.count).")
    }

    // MARK: - Internal methods

    /// Suspends until the expectation is fulfilled.
    /// - Throws: `CancellationError` when the waiting task is cancelled.
    func wait() async throws {
        try await signal.wait()
    }

    // MARK: - Private methods

    private func record(_ message: String) {
        guard Test.current != nil else {
            #if canImport(XCTest)
            XCTFail(message)
            #else
            fatalError(message)
            #endif
            return
        }

        Issue.record(
            Comment(stringLiteral: message),
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - AsyncExpectationTimeout

/// An error thrown when an expectation is not fulfilled within its timeout.
public struct AsyncExpectationTimeout: Error, CustomStringConvertible {

    /// The description of the expectation that timed out.
    public let expectation: String

    /// The number of fulfillments observed before the timeout.
    public let fulfillmentCount: Int

    /// The number of fulfillments the expectation was waiting for.
    public let expectedFulfillmentCount: Int

    /// The timeout that was exceeded, in seconds.
    public let timeout: Double

    /// Where the expectation was created.
    public let sourceLocation: SourceLocation

    public var description: String {
        """
        Expectation "\(expectation)" timed out after \(timeout) seconds with \
        \(fulfillmentCount) of \(expectedFulfillmentCount) fulfillments, \
        created at \(sourceLocation).
        """
    }

    init(_ expectation: AsyncExpectation, timeout: Double) {
        self.expectation = expectation.description
        self.fulfillmentCount = expectation.fulfillmentCount
        self.expectedFulfillmentCount = expectation.expectedFulfillmentCount
        self.timeout = timeout
        self.sourceLocation = expectation.sourceLocation
    }
}

// MARK: - expectations

/// Waits for all the provided expectations to be fulfilled within the specified timeout.
///
/// - Note: An inverted expectation that is never fulfilled can only be confirmed by waiting the
/// timeout out, so pass a short explicit `timeout` when the group contains one. An inverted
/// expectation that *is* fulfilled fails immediately.
///
/// - Parameters:
///   - expectations: An array of AsyncExpectations to wait for.
///   - timeout: The maximum time to wait for all expectations to be fulfilled, in seconds. Default is 60 seconds.
/// - Throws: `AsyncExpectationTimeout` if an expectation is not fulfilled in time, or
/// `CancellationError` if the waiting task is cancelled.
public func expectations(_ expectations: [AsyncExpectation], timeout: Double = 60) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for expectation in expectations {
            group.addTask {
                do {
                    try await withTaskTimeout(seconds: timeout) {
                        try await expectation.wait()
                    }
                } catch is TaskTimeoutError {
                    // Never fulfilled. That is the pass condition for an inverted expectation
                    // and the failure condition for every other one.
                    guard !expectation.isInverted else {
                        return
                    }

                    throw AsyncExpectationTimeout(expectation, timeout: timeout)
                }
            }
        }

        try await group.waitForAll()
    }
}

#endif
