import Foundation

actor MemoryAccessGate {
    static let shared = MemoryAccessGate()
    private struct Waiter {
        let exclusive: Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var readers = 0
    private var writing = false
    private var waiting: [Waiter] = []

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
