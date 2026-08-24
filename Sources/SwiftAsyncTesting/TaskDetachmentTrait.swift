// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

// See AsyncExpectation.swift for why this whole module degrades to empty
// rather than breaking the build on SDKs without Testing.
#if canImport(Testing)
@_spi(Testing) import SwiftAsyncStream
import Testing

/// Routes every call to `Task.detachedUnlessDisabled` through a plain, attached `Task` for the
/// duration of a test or suite — both `SwiftAsyncStream`'s own internal call sites (drain loops,
/// watchdogs, ...) and any call your own code makes to that same API.
///
/// Detaching is correct in production: it keeps that work from inheriting priority or task-local
/// values from whichever caller happened to trigger it. In tests, that same severing makes the
/// work invisible to task-local-based infrastructure such as leak trackers or expectations.
/// Applying this trait attaches it back to the test's task tree instead.
public struct TaskDetachmentDisabledTrait: TestTrait, SuiteTrait, TestScoping {

    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await TaskDetachment.$isDisabled.withValue(true) {
            try await function()
        }
    }
}

extension Trait where Self == TaskDetachmentDisabledTrait {

    /// Disables `Task.detachedUnlessDisabled` for this test or suite, so background tasks
    /// spawned through it — `SwiftAsyncStream`'s own and your own — run attached instead.
    public static var taskDetachmentDisabled: Self { Self() }
}

#endif
