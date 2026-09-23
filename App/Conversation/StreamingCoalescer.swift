import Foundation

struct StreamingCoalescer {
    private let interval: Duration
    private var pendingText = ""
    private var nextFlush: ContinuousClock.Instant?

    /// The default is only an uncalibrated starting point. The product interval still
    /// requires 60/120 Hz measurement on a real device before it becomes a rule.
    init(interval: Duration = .milliseconds(16)) {
        self.interval = interval
    }

    /// Accumulates deltas until the caller-provided instant reaches the next flush.
    /// Time is supplied by the caller so tests do not need a real clock or sleep.
    mutating func append(_ delta: String, at now: ContinuousClock.Instant) -> String? {
        guard !delta.isEmpty else { return nil }

        pendingText.append(contentsOf: delta)
        if nextFlush == nil {
            nextFlush = now.advanced(by: interval)
        }

        guard let nextFlush, now >= nextFlush else { return nil }

        let readyText = pendingText
        pendingText.removeAll(keepingCapacity: true)
        self.nextFlush = now.advanced(by: interval)
        return readyText
    }

    /// A semantic boundary is stronger than the display interval: completion and run
    /// termination must publish every held delta, even when the interval has not elapsed.
    mutating func flush() -> String? {
        guard !pendingText.isEmpty else { return nil }

        let readyText = pendingText
        pendingText.removeAll(keepingCapacity: true)
        nextFlush = nil
        return readyText
    }
}
