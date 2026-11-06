import Foundation

/// Runs slow work that blocks its thread, like reading a whole file's sound sample by sample,
/// on a few threads of its own.
///
/// Swift's async code shares a small pool of threads (one per core), and blocking them stalls
/// everything else that's async. With a timeline's waveforms, loudness, and sound levels all
/// read at once, the pool filled up and the app froze: the preview stopped following the
/// playhead and windows stopped responding.
nonisolated enum BlockingWork {
    /// At most this many run at once; the rest wait their turn.
    static let limit = 3

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SwiftCut.BlockingWork"
        queue.maxConcurrentOperationCount = limit
        queue.qualityOfService = .utility
        return queue
    }()

    /// Runs `work` off Swift's shared threads and returns its result. `isCancelled` turns true
    /// when the calling task is cancelled, so long loops can stop early.
    static func run<T: Sendable>(_ work: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) throws -> T) async throws -> T {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    if flag.isSet {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Result { try work { flag.isSet } })
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
