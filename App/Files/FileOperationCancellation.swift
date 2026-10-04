import Foundation

/// Carries cancellation into synchronous database queue hops as well as the worker Task.
final class FileOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func check() throws {
        lock.lock()
        let cancelled = cancelled
        lock.unlock()
        if cancelled || Task<Never, Never>.isCancelled { throw CancellationError() }
    }
}
