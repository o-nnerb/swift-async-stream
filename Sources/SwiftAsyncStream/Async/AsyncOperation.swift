// Copyright 2026 Brenno Giovanini de Moura
// SPDX-License-Identifier: Apache-2.0

/// A single attempt to acquire an ``AsyncLock`` or to wait on an ``AsyncSignal``.
///
/// The operation owns exactly one `UnsafeContinuation` and guarantees it is resumed exactly
/// once, either by ``run()`` (the operation got its turn) or by ``cancel()`` (the operation
/// gave up before that).
///
/// State transitions never resume the continuation themselves. They return it to the caller,
/// which is expected to resume it after releasing any lock it holds.
final class AsyncOperation: @unchecked Sendable {

    // MARK: - Inner types

    enum State: Hashable {
        /// Enqueued, waiting for its turn.
        case waiting
        /// Got its turn. The continuation was resumed.
        case running
        /// Gave up before getting its turn.
        case cancelled
    }

    struct DebugInfo: Sendable, CustomStringConvertible {

        let function: StaticString
        let file: StaticString
        let line: UInt

        var description: String {
            "\(function) at \(file):\(line)"
        }
    }

    private enum _State {
        case idle
        case scheduled(UnsafeContinuation<Void, Never>)
        case running
        case cancelled
    }

    // MARK: - Internal properties

    let debugInfo: DebugInfo

    var state: State {
        lock.withLock {
            switch _state {
            case .idle, .scheduled:
                return .waiting
            case .running:
                return .running
            case .cancelled:
                return .cancelled
            }
        }
    }

    // MARK: - Private properties

    private let lock = Lock()

    // MARK: - Unsafe properties

    private var _state: _State = .idle

    // MARK: - Inits

    init(debugInfo: DebugInfo) {
        self.debugInfo = debugInfo
    }

    // MARK: - Internal methods

    /// Stores the continuation for later resumption.
    ///
    /// - Returns: `true` when the continuation was stored. `false` when the operation was
    /// already cancelled before it could be scheduled, in which case the caller **must**
    /// resume the continuation itself.
    @discardableResult
    func schedule(_ continuation: UnsafeContinuation<Void, Never>) -> Bool {
        lock.withLock {
            switch _state {
            case .idle:
                _state = .scheduled(continuation)
                return true
            case .cancelled:
                return false
            case .scheduled, .running:
                preconditionFailure("AsyncOperation.schedule called more than once")
            }
        }
    }

    /// Transitions the operation into the running state.
    ///
    /// - Returns: The continuation to resume, or `nil` when the operation is no longer
    /// eligible to run.
    func run() -> UnsafeContinuation<Void, Never>? {
        lock.withLock { () -> UnsafeContinuation<Void, Never>? in
            guard case .scheduled(let continuation) = _state else {
                return nil
            }

            _state = .running
            return continuation
        }
    }

    /// Gives up before getting its turn.
    ///
    /// An operation that already reached ``State/running`` is never downgraded. It got its
    /// turn and owns whatever contract came with it.
    ///
    /// - Returns: The continuation to resume, or `nil` when there is nothing to resume.
    func cancel() -> UnsafeContinuation<Void, Never>? {
        lock.withLock { () -> UnsafeContinuation<Void, Never>? in
            switch _state {
            case .idle:
                _state = .cancelled
                return nil
            case .scheduled(let continuation):
                _state = .cancelled
                return continuation
            case .running, .cancelled:
                return nil
            }
        }
    }
}

// MARK: - CustomStringConvertible

extension AsyncOperation: CustomStringConvertible {

    var description: String {
        "\(state) (\(debugInfo))"
    }
}
