import Foundation

actor MemoryAccessGate {
    // Keep known-secret validation through content/result commit atomic with
    // Environment secret publication and owned cleanup across DB connections.
    // Take a handoff lease before this synchronous lock; never await with it held.
    nonisolated let environmentCredentialLock = NSRecursiveLock()
    static func forDatabase(_ path: String?) -> MemoryAccessGate { MemoryGateRegistry.shared.gate(for: path) }
    private struct Waiter {
        let exclusive: Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var readers = 0
    private var writing = false
    private var waiting: [Waiter] = []

#if DEBUG
    // Observation only: ordering regressions must prove that the real writer
    // reached this queue, instead of inferring readiness from scheduler yields.
    var hasQueuedWriterForTesting: Bool { waiting.contains { $0.exclusive } }
#endif

    func withRead<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(exclusive: false)
        defer { readers -= 1; drain() }
        return try await body()
    }

    func withWrite<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(exclusive: true)
        defer { writing = false; drain() }
        return try await body()
    }

    private func acquire(exclusive: Bool) async {
        if !writing, waiting.isEmpty, !exclusive || readers == 0 {
            if exclusive { writing = true } else { readers += 1 }
            return
        }
        await withCheckedContinuation { waiting.append(Waiter(exclusive: exclusive, continuation: $0)) }
    }

    private func drain() {
        guard !writing else { return }
        // A queued erasure cannot starve behind new provider handoffs.
        while let first = waiting.first {
            if first.exclusive {
                guard readers == 0 else { return }
                writing = true
                waiting.removeFirst().continuation.resume()
                return
            }
            readers += 1
            waiting.removeFirst().continuation.resume()
        }
    }
}

private final class WeakMemoryGate {
    weak var value: MemoryAccessGate?
    init(_ value: MemoryAccessGate) { self.value = value }
}

/// Multiple connections to one database coordinate; unrelated test/user stores
/// never wait on each other's provider handoffs. No user content is cached here.
private final class MemoryGateRegistry: @unchecked Sendable {
    static let shared = MemoryGateRegistry()
    private let lock = NSLock()
    private var byPath: [String: WeakMemoryGate] = [:]

    func gate(for path: String?) -> MemoryAccessGate {
        guard let path else { return MemoryAccessGate() }
        let key = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return lock.withLock {
            byPath = byPath.filter { $0.value.value != nil }
            if let existing = byPath[key]?.value { return existing }
            let created = MemoryAccessGate()
            byPath[key] = WeakMemoryGate(created)
            return created
        }
    }
}
