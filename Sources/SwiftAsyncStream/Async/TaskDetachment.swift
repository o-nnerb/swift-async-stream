// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

// MARK: - TaskDetachment

/// Governs whether ``Task/detachedUnlessDisabled(priority:operation:)`` actually detaches.
///
/// Production code always detaches, which is the point: the spawned work must not inherit
/// priority or task-local values from whichever caller happened to trigger it. Tests can flip
/// ``isDisabled`` — most conveniently via `SwiftAsyncTesting`'s `.taskDetachmentDisabled` trait —
/// to route calls through a plain, attached `Task` instead, so the spawned work stays reachable
/// through whatever task-local infrastructure the test carries (leak trackers, expectations,
/// ...). This affects every caller of `detachedUnlessDisabled`, not just the ones inside this
/// module.
@_spi(Testing)
public enum TaskDetachment {

    @TaskLocal public static var isDisabled = false
}

// MARK: - Task

extension Task {

    /// Spawns a `Task` the way `Task.detached` does, except a test can opt it back into the
    /// caller's task tree.
    ///
    /// In production this behaves exactly like `Task.detached`: `operation` does not inherit the
    /// caller's priority or task-local values. Inside a test scoped by `SwiftAsyncTesting`'s
    /// `.taskDetachmentDisabled` trait, it instead behaves like a plain `Task`, inheriting the
    /// caller's priority and task locals — useful so leak trackers, expectations, and other
    /// task-local-based test infrastructure can still see the spawned work.
    @discardableResult
    public static func detachedUnlessDisabled(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Success
    ) -> Task<Success, Failure> where Failure == Never {
        if TaskDetachment.isDisabled {
            Task(priority: priority, operation: operation)
        } else {
            Task.detached(priority: priority, operation: operation)
        }
    }

    /// Spawns a `Task` the way `Task.detached` does, except a test can opt it back into the
    /// caller's task tree.
    ///
    /// In production this behaves exactly like `Task.detached`: `operation` does not inherit the
    /// caller's priority or task-local values. Inside a test scoped by `SwiftAsyncTesting`'s
    /// `.taskDetachmentDisabled` trait, it instead behaves like a plain `Task`, inheriting the
    /// caller's priority and task locals — useful so leak trackers, expectations, and other
    /// task-local-based test infrastructure can still see the spawned work. A throw from
    /// `operation` does not propagate here; it is stored on the returned `Task` and surfaces from
    /// `await task.value`.
    @discardableResult
    public static func detachedUnlessDisabled(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async throws -> Success
    ) -> Task<Success, Failure> where Failure == any Error {
        if TaskDetachment.isDisabled {
            Task(priority: priority, operation: operation)
        } else {
            Task.detached(priority: priority, operation: operation)
        }
    }
}
