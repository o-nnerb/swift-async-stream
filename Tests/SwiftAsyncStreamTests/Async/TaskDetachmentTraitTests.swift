// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

import SwiftAsyncStream
import SwiftAsyncTesting
import Testing

// MARK: - Fixtures

private struct EchoJob: CoalescingJob {
    let value: String
}

// MARK: - TaskDetachmentTraitTests

/// `SerialCoalescingQueue`'s drain loop runs on `Task.detached`, so by default it must not see
/// task-local values bound by whoever triggered it.
struct TaskDetachmentTraitTests {

    @TaskLocal private static var probe: String?

    @Test
    func drainTaskDoesNotInheritTheTriggeringCallersTaskLocalsByDefault() async throws {
        let queue = SerialCoalescingQueue<EchoJob, String?>()

        let observed = try await Self.$probe.withValue("set-by-caller") {
            try await queue.submit(EchoJob(value: "a")) { _ in Self.probe }
        }

        #expect(observed == nil)
    }
}

// MARK: - TaskDetachmentDisabledTraitTests

/// Same drain loop, with ``TaskDetachmentDisabledTrait`` applied: the trait is the whole point
/// of routing production's `Task.detached` call sites through ``Task/detachedUnlessDisabled``,
/// so it must flip the outcome above.
@Suite(.taskDetachmentDisabled)
struct TaskDetachmentDisabledTraitTests {

    @TaskLocal private static var probe: String?

    @Test
    func drainTaskInheritsTheTriggeringCallersTaskLocalsWhenDisabled() async throws {
        let queue = SerialCoalescingQueue<EchoJob, String?>()

        let observed = try await Self.$probe.withValue("set-by-caller") {
            try await queue.submit(EchoJob(value: "a")) { _ in Self.probe }
        }

        #expect(observed == "set-by-caller")
    }
}
