// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

// See AsyncExpectation.swift for why this whole module degrades to empty
// rather than breaking the build on SDKs without Testing.
#if canImport(Testing)
@_spi(Testing) import SwiftAsyncStream
import Testing

/// Routes every internal `Task.detached` call site in `SwiftAsyncStream` through a plain,
/// attached `Task` for the duration of a test or suite.
///
/// Detaching is correct in production: it keeps background bookkeeping tasks (drain loops,
/// watchdogs, ...) from inheriting priority or task-local values from whichever caller happened
/// to trigger them. In tests, that same severing makes those tasks invisible to task-local-based
/// infrastructure such as leak trackers or expectations. Applying this trait attaches them back
/// to the test's task tree instead.
public struct TaskDetachmentDisabledTrait: TestTrait, SuiteTrait, TestScoping {

    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await TaskDetachment.$isDisabled.withValue(true, operation: function)
    }
}

extension Trait where Self == TaskDetachmentDisabledTrait {

    /// Disables `Task.detached` inside `SwiftAsyncStream` for this test or suite, so its
    /// internal background tasks run attached instead.
    public static var taskDetachmentDisabled: Self { Self() }
}

#endif
