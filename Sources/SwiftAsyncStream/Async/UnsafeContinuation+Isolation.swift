// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// `withUnsafeContinuation`, pinned to `isolation` so resuming it never hops off the caller's
/// actor.
///
/// Swift 6.4 deprecated the `isolation:`-parameterized overload of `withUnsafeContinuation` in
/// favor of a `nonisolated(nonsending)` one that infers the caller's isolation instead of taking
/// it as an explicit argument. This package's minimum supported toolchain is Swift 6.2, which
/// does not have that overload yet, so both forms are kept behind a compiler check.
@inline(__always)
func withIsolatedUnsafeContinuation<T>(
    isolation: isolated (any Actor)?,
    _ fn: (UnsafeContinuation<T, Never>) -> Void
) async -> T {
    #if compiler(>=6.4)
    await withUnsafeContinuation(fn)
    #else
    await withUnsafeContinuation(isolation: isolation, fn)
    #endif
}
