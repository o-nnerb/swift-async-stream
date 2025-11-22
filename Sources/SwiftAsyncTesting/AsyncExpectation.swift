@_exported import SwiftAsyncStream
import Testing
#if canImport(Darwin)
import XCTest
#endif

public struct AsyncExpectation: Sendable {

    private class Storage: @unchecked Sendable {

        var fulfillmentCount: Int {
            get { lock.withLock { _fulfillmentCount }}
            set { lock.withLock { _fulfillmentCount = newValue }}
        }

        var expectedFulfillmentCount: Int {
            get { lock.withLock { _expectedFulfillmentCount }}
            set { lock.withLock { _expectedFulfillmentCount = newValue }}
        }

        var assertForOverFulfill: Bool {
            get { lock.withLock { _assertForOverFulfill }}
            set { lock.withLock { _assertForOverFulfill = newValue }}
        }

        var isInverted: Bool {
            get { lock.withLock { _isInverted }}
            set { lock.withLock { _isInverted = newValue }}
        }


        private let lock = NSLock()

        private var _fulfillmentCount: Int = .zero
        private var _expectedFulfillmentCount: Int = 1
        private var _assertForOverFulfill: Bool = true
        private var _isInverted: Bool = false
    }

    public var expectedFulfillmentCount: Int {
        get { storage.expectedFulfillmentCount }
        nonmutating set {
            precondition(newValue >= storage.fulfillmentCount)
            storage.expectedFulfillmentCount = newValue
        }
    }

    public var assertForOverFulfill: Bool {
        get { storage.assertForOverFulfill }
        nonmutating set { storage.assertForOverFulfill = newValue }
    }

    public var isInverted: Bool {
        get { storage.isInverted }
        nonmutating set { storage.isInverted = newValue }
    }

    private let semaphore = AsyncSignal()

    private let storage = Storage()

    private let description: String
    private let fileID: String
    private let filePath: String
    private let line: Int
    private let column: Int

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

    public func fulfill() {
        guard !storage.isInverted else {
            fulfilledWhenInverted()
            return
        }

        storage.fulfillmentCount += 1

        if storage.fulfillmentCount == expectedFulfillmentCount {
            semaphore.signal()
            return
        }

        guard
            storage.fulfillmentCount > expectedFulfillmentCount,
            storage.assertForOverFulfill
        else { return }

        let message = """
        Expected fulfill count to be \(storage.expectedFulfillmentCount), \
        got \(storage.fulfillmentCount).
        """

        if Test.current != nil {
            Issue.record(
                Comment(stringLiteral: message),
                sourceLocation: .init(
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            )
        } else {
            #if canImport(Darwin)
            XCTFail(message)
            #else
            fatalError("No test running")
            #endif
        }
    }

    func wait() async {
        await semaphore.wait()
    }

    private func fulfilledWhenInverted() {
        let message = "Inverted expectation was fulfilled, which is a failure."

        if Test.current != nil {
            Issue.record(
                Comment(stringLiteral: message),
                sourceLocation: .init(
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            )
        } else {
            XCTFail(message)
        }
    }
}

public func expectations(_ expectations: [AsyncExpectation], timeout: TimeInterval = 60) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for expectation in expectations {
            group.addTask {
                do {
                    try await withTaskTimeout(seconds: timeout) {
                        await expectation.wait()
                    }
                } catch {
                    if expectation.isInverted {
                        return
                    } else {
                        throw error
                    }
                }
            }
        }

        try await group.waitForAll()
    }
}
