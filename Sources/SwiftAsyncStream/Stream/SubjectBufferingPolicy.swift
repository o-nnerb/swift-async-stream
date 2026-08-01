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

    /// Keeps every element until the first iterator is created, then hands the buffer over to
    /// that consumer and stops holding anything itself.
    ///
    /// This is for the common shape where a subject has to tolerate a late first reader but is
    /// only ever read once: nothing is missed, and once reading starts the retained memory
    /// drops to the gap between the producer and that reader instead of staying at everything
    /// ever published.
    ///
    /// - Important: Single use. A second iterator has nothing left to replay, so asking for one
    /// traps rather than quietly returning whatever survived, which would be a partial result
    /// that varies with timing.
    ///
    /// - Important: Only ``ReplaySubject`` can honour this. The other subjects subscribe at the
    /// tail or at the latest element, never at the head, so they would hold the buffer forever
    /// and never release it. Passing it to them traps at construction.
    ///
    /// - Note: The prefix kept before the first iteration is unbounded. Capping it would mean
    /// discarding elements that the whole point of the mode is to preserve.
    case untilFirstIteration
}
