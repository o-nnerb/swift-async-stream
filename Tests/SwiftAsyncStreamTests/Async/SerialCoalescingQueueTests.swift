// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

@_spi(Testing) import SwiftAsyncStream
import Testing

// MARK: - Fixtures

private struct MockJob: CoalescingJob {

    let id: String
    let isCoalescable: Bool

    init(id: String, isCoalescable: Bool = true) {
        self.id = id
        self.isCoalescable = isCoalescable
    }
}

private enum MockError: Error, Equatable {
    case failure
}

/// Blocks an operation until the test releases it, keeping the queue busy for a
/// known window.
private actor Gate {

    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        guard !isOpen else {
            return
        }

        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true

        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor Recorder {

    private(set) var ids = [String]()
    private(set) var maxConcurrency = 0

    private var active = 0
    private var waiters = [(target: Int, continuation: CheckedContinuation<Void, Never>)]()

    var count: Int {
        ids.count
    }

    func begin(_ job: MockJob) {
        ids.append(job.id)
        active += 1
        maxConcurrency = max(maxConcurrency, active)

        let ready = waiters.filter { ids.count >= $0.target }
        waiters.removeAll { ids.count >= $0.target }

        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func end() {
        active -= 1
    }

    func waitForExecutions(_ target: Int) async {
        guard ids.count < target else {
            return
        }

        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

@available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
private struct Fixture: Sendable {

    let queue = SerialCoalescingQueue<MockJob, String>()
    let recorder = Recorder()
    let gate = Gate()

    /// Starts a job that parks inside the gate and returns once it is executing,
    /// so every later submit is guaranteed to find the queue busy.
    @discardableResult
    func startLeader(_ job: MockJob = MockJob(id: "leader")) async -> Task<String, Error> {
        let task = Task {
            try await queue.submit(job) { job in
                await recorder.begin(job)
                await gate.wait()
                await recorder.end()
                return "leader"
            }
        }

        await recorder.waitForExecutions(1)
        return task
    }

    /// Submits and waits for the caller to be visible in the queue, so submits
    /// land in the order the test writes them.
    @discardableResult
    func enqueue(
        _ job: MockJob,
        returning value: String = "value",
        failing error: MockError? = nil,
        expecting pending: Int
    ) async throws -> Task<String, Error> {
        let task = Task {
            try await queue.submit(job) { job in
                await recorder.begin(job)
                await recorder.end()

                if let error {
                    throw error
                }

                return value
            }
        }

        try await queue.waitForPendingWaiters(pending)
        return task
    }

    func release() async {
        await gate.open()
        await queue.waitUntilIdle()
    }
}

// MARK: - Tests

@Suite(.serialized)
struct SerialCoalescingQueueTests {

    // MARK: - Coalescing

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func coalescesEveryCallerQueuedWhileTheLeaderRuns() async throws {
        let fixture = Fixture()
        let job = MockJob(id: "refresh")

        await fixture.startLeader()

        let first = try await fixture.enqueue(job, expecting: 1)
        let second = try await fixture.enqueue(job, expecting: 2)
        let third = try await fixture.enqueue(job, expecting: 3)

        #expect(await fixture.queue.pendingBatchCount == 1)

        await fixture.release()

        #expect(try await first.value == "value")
        #expect(try await second.value == "value")
        #expect(try await third.value == "value")
        #expect(await fixture.recorder.count == 2)
    }

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func keepsSeparateBatchesForJobsThatAreNotAdjacentAndEqual() async throws {
        let fixture = Fixture()
        let jobA = MockJob(id: "A")
        let jobB = MockJob(id: "B")

        await fixture.startLeader()

        try await fixture.enqueue(jobA, expecting: 1)
        try await fixture.enqueue(jobA, expecting: 2)
        try await fixture.enqueue(jobB, expecting: 3)
        try await fixture.enqueue(jobA, expecting: 4)

        #expect(await fixture.queue.pendingBatchCount == 3)

        await fixture.release()

        #expect(await fixture.recorder.ids == ["leader", "A", "B", "A"])
    }

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func neverCoalescesJobsThatOptOut() async throws {
        let fixture = Fixture()
        let job = MockJob(id: "select", isCoalescable: false)

        await fixture.startLeader()

        try await fixture.enqueue(job, expecting: 1)
        try await fixture.enqueue(job, expecting: 2)
        try await fixture.enqueue(job, expecting: 3)

        #expect(await fixture.queue.pendingBatchCount == 3)

        await fixture.release()

        #expect(await fixture.recorder.count == 4)
    }

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func runsTheOperationSuppliedByTheCallerThatCreatedTheBatch() async throws {
        let fixture = Fixture()
        let job = MockJob(id: "refresh")

        await fixture.startLeader()

        let first = try await fixture.enqueue(job, returning: "first", expecting: 1)
        let second = try await fixture.enqueue(job, returning: "second", expecting: 2)

        await fixture.release()

        // Equal jobs are assumed to have interchangeable operations. The second
        // closure is dropped on purpose.
        #expect(try await first.value == "first")
        #expect(try await second.value == "first")
    }

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func propagatesFailureToEveryCallerInTheBatch() async throws {
        let fixture = Fixture()
        let job = MockJob(id: "refresh")

        await fixture.startLeader()

        let first = try await fixture.enqueue(job, failing: .failure, expecting: 1)
        let second = try await fixture.enqueue(job, failing: .failure, expecting: 2)

        await fixture.release()

        await #expect(throws: MockError.failure) { try await first.value }
        await #expect(throws: MockError.failure) { try await second.value }
        #expect(await fixture.recorder.count == 2)
    }

    // MARK: - Serialization

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func neverRunsTwoOperationsConcurrently() async throws {
        let fixture = Fixture()

        await fixture.startLeader()

        for index in 1...5 {
            try await fixture.enqueue(MockJob(id: "job-\(index)"), expecting: index)
        }

        await fixture.release()

        #expect(await fixture.recorder.maxConcurrency == 1)
        #expect(await fixture.recorder.count == 6)
    }

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func startsANewDrainAfterGoingIdle() async throws {
        let fixture = Fixture()
        let job = MockJob(id: "refresh")

        await fixture.startLeader()
        await fixture.release()

        #expect(await fixture.recorder.count == 1)

        let value = try await fixture.queue.submit(job) { job in
            await fixture.recorder.begin(job)
            await fixture.recorder.end()
            return "again"
        }

        #expect(value == "again")
        #expect(await fixture.recorder.count == 2)
    }

    // MARK: - Cancellation

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func keepsTheBatchWhenOneOfItsCallersIsCancelled() async throws {
        let fixture = Fixture()
        let job = MockJob(id: "refresh")

        await fixture.startLeader()

        let first = try await fixture.enqueue(job, expecting: 1)
        let second = try await fixture.enqueue(job, expecting: 2)
        let third = try await fixture.enqueue(job, expecting: 3)

        second.cancel()
        try await fixture.queue.waitForPendingWaiters(2)

        #expect(await fixture.queue.pendingBatchCount == 1)

        await fixture.release()

        #expect(try await first.value == "value")
        #expect(try await third.value == "value")
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await fixture.recorder.count == 2)
    }

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func dropsTheBatchWhenEveryCallerIsCancelled() async throws {
        let fixture = Fixture()
        let job = MockJob(id: "refresh")

        await fixture.startLeader()

        let first = try await fixture.enqueue(job, expecting: 1)
        let second = try await fixture.enqueue(job, expecting: 2)

        first.cancel()
        second.cancel()
        try await fixture.queue.waitForPendingWaiters(.zero)

        #expect(await fixture.queue.pendingBatchCount == .zero)

        await fixture.release()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await fixture.recorder.count == 1)
    }

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func resumesACallerCancelledBeforeItReachesTheQueue() async throws {
        let fixture = Fixture()
        let release = Gate()
        let started = Gate()
        let job = MockJob(id: "refresh")

        let task = Task {
            await started.open()
            await release.wait()

            return try await fixture.queue.submit(job) { job in
                await fixture.recorder.begin(job)
                await fixture.recorder.end()
                return "value"
            }
        }

        await started.wait()
        task.cancel()
        await release.open()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.recorder.count == .zero)
    }

    @available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
    @Test
    func deliversTheResultToACallerCancelledWhileItsBatchRuns() async throws {
        let fixture = Fixture()

        let leader = await fixture.startLeader()

        // The batch already left the queue, so cancelling is a no op and the
        // caller is resumed with the value. Cancellation is cooperative.
        leader.cancel()

        await fixture.release()

        #expect(try await leader.value == "leader")
    }
}
