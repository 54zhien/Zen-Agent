import Foundation

/// Coalesces provider text before it becomes a persistence event.
///
/// The threshold is deliberately private implementation policy. Callers can rely on
/// `flush()` at semantic boundaries, but cannot accidentally make a UI or product
/// contract out of a particular byte count.
struct StreamingAccumulator: Sendable {
    private static let accumulationThresholdBytes = 1_024

    private var buffer = ""

    init() {}

    /// Adds a delta and returns a snapshot only when the implementation threshold is
    /// reached. Empty deltas do not create persistence work.
    mutating func append(_ delta: String) -> String? {
        guard !delta.isEmpty else { return nil }
        buffer.append(delta)
        guard buffer.utf8.count >= Self.accumulationThresholdBytes else { return nil }
        return flush()
    }

    /// Returns all text accumulated since the previous flush.
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let result = buffer
        buffer.removeAll(keepingCapacity: true)
        return result
    }
}

