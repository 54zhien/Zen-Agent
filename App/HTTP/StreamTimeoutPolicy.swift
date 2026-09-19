import Foundation

/// The deadlines a stream runs under.
///
/// **Two ideas of "no progress", kept apart on purpose.** They fail for different
/// reasons and point at different fixes, and a single timer cannot express both:
///
/// | question | what answers it | what counts as progress |
/// |---|---|---|
/// | is the connection alive? | `transportInactivity` | **any byte**, including a `: keep-alive` |
/// | is the model producing? | `firstEvent` / `betweenEvents` | **only a dispatched event** |
///
/// A provider that sends heartbeats while it thinks is keeping the connection open and
/// saying nothing about the answer. Collapsing the two would either kill a request the
/// provider was still working on, or wait forever on a connection that had quietly died
/// — and the resulting error text would point at the wrong layer
/// (`Agent Runtime.md:151-153`).
///
/// The values are a starting point, not a finding. The design notes say explicitly that
/// second counts are not to be taken from the notes and should be settled by observed
/// provider behaviour (`Agent Runtime.md:297`), so these are generous rather than
/// aggressive, and they are parameters rather than constants.
struct StreamTimeoutPolicy: Sendable, Equatable {
    /// The longest gap between bytes before the connection is presumed dead.
    ///
    /// A keep-alive resets this. It is evidence about the connection, which is the only
    /// thing this deadline is asking about.
    var transportInactivity: Duration

    /// The longest wait for the first event that carries model output.
    ///
    /// Deliberately the most generous of the three: DeepSeek holds a request for up to
    /// several minutes before it starts generating, sending keep-alives throughout. Being
    /// impatient here would abort requests the provider was still working on.
    var firstEvent: Duration

    /// The longest gap between two events, once the first has arrived.
    ///
    /// Tighter than `firstEvent` because the situation is different: generation has
    /// started, deltas come continuously, and a silence this long means something has
    /// gone wrong rather than that the model is still warming up.
    var betweenEvents: Duration

    /// How often the deadlines above are checked.
    ///
    /// A configuration value rather than a constant somewhere in a loop, because how
    /// often a deadline is *checked* is part of what the deadline means.
    var checkInterval: Duration

    static let `default` = StreamTimeoutPolicy(
        transportInactivity: .seconds(180),
        firstEvent: .seconds(650),
        betweenEvents: .seconds(180),
        checkInterval: .seconds(1)
    )
}

/// When a stream last made progress, on whichever question is being asked.
///
/// Shared between a reader and its watchdog, which run concurrently. Lock-protected
/// rather than an actor: the reader touches this once per byte, and an actor hop per byte
/// would cost more than the network does.
final class StreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    private var started = false

    init() {}

    /// Whether anything has arrived at all yet.
    ///
    /// The same fact as "one byte has been delivered", kept here rather than beside it:
    /// two pieces of bookkeeping for one question is how they come to disagree.
    var hasAdvanced: Bool { lock.withLock { started } }

    /// Records progress, which rearms whatever deadline is being measured.
    func advanced() {
        lock.withLock {
            last = ContinuousClock.now
            started = true
        }
    }

    /// The deadline that has elapsed, or `nil` if none has.
    ///
    /// Returns which one rather than a bare boolean so the error can say whether the
    /// wait was for the first event or between two, which is the difference between
    /// "the model never started" and "the model stopped partway".
    func elapsedDeadline(first: Duration, then subsequent: Duration) -> Duration? {
        lock.withLock {
            let window = started ? subsequent : first
            return ContinuousClock.now - last > window ? window : nil
        }
    }
}

/// Runs a stream's reader and its deadline check together, and ends whichever finishes
/// second.
///
/// One mechanism used twice: the transport counts bytes, the adapter counts events. The
/// two must not share a timer — that is the whole point of having two — but the
/// machinery that keeps a deadline honest is identical, and writing it twice would be
/// writing it twice.
///
/// No clock abstraction. Tests drive it with deadlines measured in milliseconds, which
/// the notes allow and which keeps the mechanism small enough to read. An injected clock
/// would be the right answer if these were the only way to test timing behaviour; they
/// are not.
enum StreamDeadline {

    /// Runs `reading` and a watchdog that calls `onTimeout` if `progress` goes stale.
    ///
    /// The watchdog ending the stream cancels the reader, which is what makes a blocked
    /// read let go — a reader waiting on a silent socket has no other way to notice.
    static func run(
        progress: StreamProgress,
        first: Duration,
        subsequent: Duration,
        checkInterval: Duration,
        onTimeout: @escaping @Sendable (Duration) -> Void,
        reading: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask(operation: reading)
            group.addTask {
                while !Task.isCancelled {
                    // `try?` because cancellation is the expected way out of this loop,
                    // not a failure worth propagating.
                    try? await Task.sleep(for: checkInterval)
                    if Task.isCancelled { return }
                    if let elapsed = progress.elapsedDeadline(first: first, then: subsequent) {
                        onTimeout(elapsed)
                        return
                    }
                }
            }
            // Whichever finishes first ends the other.
            await group.next()
            group.cancelAll()
        }
    }
}
