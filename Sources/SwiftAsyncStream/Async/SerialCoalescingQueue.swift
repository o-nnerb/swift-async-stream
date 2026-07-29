// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

// MARK: - CoalescingJob

/// A unit of work submitted to a `SerialCoalescingQueue`.
///
/// Two jobs share a single execution only when they are equal, coalescable and
/// adjacent in the queue. Equality is the whole policy: variants that must not
/// share an execution simply have to compare unequal.
public protocol CoalescingJob: Equatable, Sendable {

    /// Whether equal jobs queued back to back may share one execution.
    ///
    /// Defaults to `true`. Conforming types can return `false` to opt out of
    /// coalescing, ensuring that every submitted instance gets its own execution.
    var isCoalescable: Bool { get }
}

public extension CoalescingJob {

    /// A default implementation that allows equal adjacent jobs to share an execution.
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
///
/// - Important: `operation` must be a function of `job`. When two submissions coalesce, only
/// the first `operation` runs and the second is discarded, so equal jobs carrying different
/// closures would silently hand back the wrong work.
///
/// - Important: The queue is serial and offers no reentrancy. An `operation` that submits back
/// into the same queue deadlocks: the new batch is enqueued behind the drain that is waiting on
/// the very operation making the call.
public actor SerialCoalescingQueue<Job: CoalescingJob, Output: Sendable> {

    /// A closure that performs the work for a given `Job`.
    ///
    /// The operation receives the job to be executed and must be `Sendable`
    /// since it will be executed within an actor's isolated context.
    public typealias Operation = @Sendable (Job) async throws -> Output

    fileprivate struct Waiter {
        let id: Int
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

    // A waiter only has to be distinguishable from the other waiters of this queue, and IDs are
    // handed out under actor isolation, so a counter beats a UUID on every axis: no entropy, no
    // allocation, cheaper comparisons, and no Foundation dependency.
    private var nextWaiterID = 0

    // The dispatched batch is deliberately out of `batches` so it can no longer be joined or
    // cancelled, which also makes it invisible. Kept here purely so a stalled queue can name
    // the job that is holding it, instead of only listing the ones waiting behind it.
    private var runningBatch: Batch?

    /// A snapshot of the queue, naming the job currently executing and the ones behind it.
    ///
    /// Actor isolated, so read it with `await queue.debugDescription`.
    public var debugDescription: String {
        let running = runningBatch.map {
            "\($0.job) (\($0.waiters.count) waiters)"
        }

        let pending = batches
            .map { "  - \($0.job) (\($0.waiters.count) waiters)" }
            .joined(separator: "\n")

        return """
            SerialCoalescingQueue
            running: \(running ?? "none")
            pending (\(batches.count)):
            \(pending.isEmpty ? "  - none" : pending)
            """
    }

    /// Creates a new, empty queue.
    public init() {}

    /// Submits a job to the queue to be executed.
    ///
    /// If the queue is empty or the last job in the queue is different (or not coalescable),
    /// the job is appended to the queue. If the last job is equal and coalescable,
    /// the current call simply joins the existing batch and waits for its result.
    ///
    /// - Parameters:
    ///   - job: The work unit to be submitted.
    ///   - operation: The closure that executes the job and returns a result.
    /// - Returns: The output produced by the `operation`.
    /// - Throws: Any error thrown by the `operation`, or `CancellationError` if the task
    ///           is cancelled before or during execution.
    public func submit(_ job: Job, operation: @escaping Operation) async throws -> Output {
        let id = nextWaiterID
        nextWaiterID += 1

        let result = await withTaskCancellationHandler {
            await enqueue(id: id, job: job, operation: operation)
        } onCancel: {
            // Hopping is the only option: the state is actor isolated and
            // `onCancel` is synchronous and nonisolated. `Task` rather than
            // `Task.detached` so the hop keeps the cancelling caller's priority
            // instead of dropping to the default one.
            //
            // Landing late is harmless. Arriving before `enqueue` leaves the waiter to the
            // `Task.isCancelled` check, and arriving after dispatch leaves it to the batch.
            // Every path ends with somebody resuming the continuation.
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

    /// The job currently executing, if any.
    ///
    /// Not part of `pendingBatchCount` or `pendingWaiterCount`: a dispatched batch has left
    /// the queue.
    var runningJob: Job? {
        runningBatch?.job
    }

    /// Suspends until `pendingWaiterCount` settles on `count`.
    ///
    /// Creating a `Task` does not decide when it reaches the actor, so a test that
    /// needs a known queue shape has to wait for it instead of assuming it.
    func waitForPendingWaiters(
        _ count: Int,
        timeout: Double = 2
    ) async throws {
        try await waitForCount(count, timeout: timeout) { self.pendingWaiterCount }
    }
}

// MARK: - Enqueueing

private extension SerialCoalescingQueue {

    func enqueue(
        id: Int,
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
    func cancel(_ id: Int) {
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
            runningBatch = nil
            // Breaks the actor to task retain cycle. Clearing it from inside the
            // task is fine, a running task keeps itself alive.
            drainTask = nil
        }

        while !batches.isEmpty {
            let batch = batches.removeFirst()
            runningBatch = batch

            let result: Result<Output, Error>

            do {
                result = .success(try await batch.operation(batch.job))
            } catch {
                result = .failure(error)
            }

            runningBatch = nil
            batch.waiters.forEach { $0.continuation.resume(returning: result) }
        }
    }
}
