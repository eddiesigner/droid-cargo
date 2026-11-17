import Foundation
import Synchronization

public enum TransferRunState: Sendable {
    case running
    case paused
}

/// Shared pause switch checked by transports between chunks.
///
/// Pausing keeps the connection open and simply stops reading or writing, so
/// resuming continues from the same byte instead of restarting the file.
public final class TransferControl: Sendable {
    private let state = Mutex<TransferRunState>(.running)

    public init() {}

    public var runState: TransferRunState {
        state.withLock { $0 }
    }

    public func set(_ newState: TransferRunState) {
        state.withLock { $0 = newState }
    }

    /// Suspends while paused. Throws `CancellationError` when the task is cancelled.
    public func checkpoint() async throws {
        while runState == .paused {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }
}
