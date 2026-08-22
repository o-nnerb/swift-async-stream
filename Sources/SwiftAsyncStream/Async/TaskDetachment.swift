// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

// MARK: - TaskDetachment

/// Governs whether the module's internal `Task.detached` call sites actually detach.
///
/// Production code always detaches, which is the point: the spawned work must not inherit
/// priority or task-local values from whichever caller happened to trigger it. Tests can flip
/// ``isDisabled`` to route those same call sites through a plain, attached `Task` instead, so
/// the spawned work stays reachable through whatever task-local infrastructure the test carries
/// (leak trackers, expectations, ...).
@_spi(Testing)
public enum TaskDetachment {

    @TaskLocal public static var isDisabled = false
}

// MARK: - Task

extension Task {

    /// Detaches, unless ``TaskDetachment/isDisabled`` is set, in which case it spawns a plain
    /// `Task` that inherits the caller's priority and task locals instead.
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

    /// Detaches, unless ``TaskDetachment/isDisabled`` is set, in which case it spawns a plain
    /// `Task` that inherits the caller's priority and task locals instead.
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
