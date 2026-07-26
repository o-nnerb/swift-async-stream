// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - CoalescingJob

/// A unit of work submitted to a `SerialCoalescingQueue`.
///
/// Two jobs share a single execution only when they are equal, coalescable and
/// adjacent in the queue. Equality is the whole policy: variants that must not
/// share an execution simply have to compare unequal.
public protocol CoalescingJob: Equatable, Sendable {

    /// Whether equal jobs queued back to back may share one execution.
    var isCoalescable: Bool { get }
}

public extension CoalescingJob {

    var isCoalescable: Bool { true }
}

// MARK: - SerialCoalescingQueue

/// Serializes every submission and collapses adjacent runs of equal jobs into a
/// single execution.
///
/// Coalescing happens on the way in, not on the way out: a job equal to the one
/// already sitting at the tail joins it instead of taking a slot of its own. The
/// queue therefore holds one entry per distinct adjacent run, no matter how many
/// callers that run represents.
///
/// Batched callers never receive stale data. A batch stops accepting callers the
/// moment it leaves the queue to execute, so every caller in it called before the
/// execution started.
public actor SerialCoalescingQueue<Job: CoalescingJob, Output: Sendable> {

    public typealias Operation = @Sendable (Job) async throws -> Output

    fileprivate struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Result<Output, Error>, Never>
    }

    fileprivate struct Batch {
        let job: Job
        let operation: Operation
        var waiters: [Waiter]
    }

    private var batches = [Batch]()
    private var isRunning = false
    private var drainTask: Task<Void, Never>?

    public init() {}

    public func submit(_ job: Job, operation: @escaping Operation) async throws -> Output {
        let id = UUID()

        let result = await withTaskCancellationHandler {
            await enqueue(id: id, job: job, operation: operation)
        } onCancel: {
            // Hopping is the only option: the state is actor isolated and
            // `onCancel` is synchronous and nonisolated. `Task` rather than
            // `Task.detached` so the hop keeps the cancelling caller's priority
            // instead of dropping to the default one.
            Task { await self.cancel(id) }
        }

        return try result.get()
    }

    /// Waits until no drain is running. Meant for tests, so a suite can join the
    /// unstructured drain before tearing its task locals down.
    ///
    /// Loops rather than awaiting once: a submit landing while the previous drain
    /// finishes starts a fresh one.
    public func waitUntilIdle() async {
        while let task = drainTask {
            await task.value
        }
    }
}

// MARK: - Testing

@_spi(Testing)
public extension SerialCoalescingQueue {

    /// Batches waiting to be dispatched.
    var pendingBatchCount: Int {
        batches.count
    }

    /// Callers waiting across every pending batch.
    var pendingWaiterCount: Int {
        batches.reduce(.zero) { $0 + $1.waiters.count }
    }

    /// Suspends until `pendingWaiterCount` settles on `count`.
    ///
    /// Creating a `Task` does not decide when it reaches the actor, so a test that
    /// needs a known queue shape has to wait for it instead of assuming it.
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    func waitForPendingWaiters(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while pendingWaiterCount != count {
            guard ContinuousClock.now < deadline else {
                throw PendingWaitersTimeout(expected: count, found: pendingWaiterCount)
            }

            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@_spi(Testing)
public struct PendingWaitersTimeout: Error, CustomStringConvertible {

    let expected: Int
    let found: Int

    public var description: String {
        "Timed out waiting for \(expected) pending waiters, found \(found)"
    }
}

// MARK: - Enqueueing

private extension SerialCoalescingQueue {

    func enqueue(
        id: UUID,
        job: Job,
        operation: @escaping Operation
    ) async -> Result<Output, Error> {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                return continuation.resume(returning: .failure(CancellationError()))
            }

            let waiter = Waiter(id: id, continuation: continuation)

            // Only the tail is joinable. Anything already dispatched is out of
            // `batches`, so joining can never hand back a result older than this
            // call.
            if job.isCoalescable, let index = batches.indices.last, batches[index].job == job {
                batches[index].waiters.append(waiter)
            } else {
                batches.append(Batch(job: job, operation: operation, waiters: [waiter]))
            }

            startIfNeeded()
        }
    }

    /// Cancels a caller that has not been dispatched yet.
    ///
    /// A caller whose batch already left the queue is not found here and gets
    /// resumed by the batch. Cutting it loose would not stop the execution the
    /// rest of the batch depends on.
    ///
    /// When the last caller of a batch cancels, the batch is dropped and never
    /// runs.
    func cancel(_ id: UUID) {
        for index in batches.indices {
            guard let waiterIndex = batches[index].waiters.firstIndex(where: { $0.id == id }) else {
                continue
            }

            let waiter = batches[index].waiters.remove(at: waiterIndex)

            if batches[index].waiters.isEmpty {
                batches.remove(at: index)
            }

            return waiter.continuation.resume(returning: .failure(CancellationError()))
        }
    }
}

// MARK: - Draining

private extension SerialCoalescingQueue {

    func startIfNeeded() {
        guard !isRunning, !batches.isEmpty else {
            return
        }

        isRunning = true

        drainTask = Task { await self.drain() }
    }

    func drain() async {
        defer {
            isRunning = false
            // Breaks the actor to task retain cycle. Clearing it from inside the
            // task is fine, a running task keeps itself alive.
            drainTask = nil
        }

        while !batches.isEmpty {
            let batch = batches.removeFirst()
            let result: Result<Output, Error>

            do {
                result = .success(try await batch.operation(batch.job))
            } catch {
                result = .failure(error)
            }

            batch.waiters.forEach { $0.continuation.resume(returning: result) }
        }
    }
}
