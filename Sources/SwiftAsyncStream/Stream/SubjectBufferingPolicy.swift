// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// How a subject bounds the elements it keeps for consumers that fall behind.
///
/// Elements live in a chain that every consumer walks forward, so the chain can only be
/// released once the slowest consumer moves past it. Without a bound, one stalled consumer
/// pins every element published since it stalled.
///
/// - Note: There is no `bufferingOldest` counterpart. Dropping the newest element would mean a
/// subject whose latest published value is invisible to consumers that are up to date, which is
/// the opposite of what a broadcast subject is for. Producers here are synchronous and never
/// suspend, so back pressure can only be applied by discarding.
public enum SubjectBufferingPolicy: Sendable, Equatable {

    /// Keeps every element until the slowest consumer has seen it.
    case unbounded

    /// Keeps at most `limit` elements, discarding the oldest ones first.
    ///
    /// A consumer parked on a discarded element is woken and skips forward, so it observes a
    /// gap rather than stalling. `limit` must be at least one.
    case bufferingNewest(Int)
}
