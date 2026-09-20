import Foundation

/// The deadlines a stream runs under.
///
/// **Three ideas of "no progress", kept apart on purpose.** They fail for different
/// reasons and point at different fixes, and a single timer cannot express all three:
///
/// | question | what answers it | what counts as progress |
/// |---|---|---|
/// | is the connection alive? | `transportInactivity` | **any byte**, including a `: keep-alive` |
/// | is this refused body worth waiting for? | `errorBodyDeadline` | **nothing** — it only moves forward |
/// | is the model producing? | `firstEvent` / `betweenEvents` | **only a dispatched event** |
///
/// A provider that sends heartbeats while it thinks is keeping the connection open and
/// saying nothing about the answer. Collapsing any two of them would either kill a
/// request the provider was still working on, wait forever on a connection that had
/// quietly died, or keep reading a refusal's envelope long after it had stopped being
/// worth reading — and the resulting error text would point at the wrong layer
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

    /// The longest a **refused response's body** may take, as a **total patience for
    /// reading a diagnostic body once a non-2xx head has arrived** — counted from the
    /// moment the read starts rather than from the last byte that arrived.
    ///
    /// **Absolute, unlike the others.** `transportInactivity` asks "is the connection
    /// alive", and every byte answers yes; this asks "is this body worth waiting for",
    /// and no byte changes the answer. That is the difference between a window and a
    /// total, and it is the whole reason this field exists: a server that trickles a
    /// byte at intervals shorter than `transportInactivity` keeps the liveness window
    /// happy forever, and the cap on the body's *size* bounds space rather than time —
    /// so without this, an endless trickle is a read that never returns.
    ///
    /// Far tighter than `firstEvent`, deliberately, and the comparison is about what is
    /// being waited on rather than about how the bytes travel. `firstEvent` waits on a
    /// model that has to be *run* before it can say anything, which is why it is the most
    /// generous of all of them; this one is only ever started **after** the non-2xx head
    /// has been received, so the server has already refused and already has an envelope
    /// to write. Nothing here waits on work that has not begun.
    ///
    /// It does **not** claim that HTTP delivers the status line and the envelope
    /// together. The head is all this transport has seen; the body that follows may come
    /// at once, may trickle, and may never finish — which is precisely why this is a
    /// deadline and not a formality. What justifies making it tight is that the server
    /// side of the work is already done, not that the bytes are already on the wire.
    ///
    /// The value is generous for the job it does — an envelope is a small JSON document,
    /// and this is orders of magnitude more time than one needs on any working
    /// connection — while still ending a body that has stopped being worth the wait.
    var errorBodyDeadline: Duration

    /// The longest wait for the first event that carries model output.
    ///
    /// Deliberately the most generous of them all: DeepSeek holds a request for up to
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
        // Tighter than `firstEvent` by design, and tighter than `transportInactivity`
        // too. A server that has already refused does not need three minutes to hand over
        // the envelope it refused with, and a refusal is a case where saying so promptly
        // is worth more than waiting.
        errorBodyDeadline: .seconds(15),
        firstEvent: .seconds(650),
        betweenEvents: .seconds(180),
        checkInterval: .seconds(1)
    )
}

extension Duration {
    /// For the one API that still speaks `TimeInterval`: `URLRequest.timeoutInterval`.
    ///
    /// Lossy in principle, and exactly representable for every value this project uses —
    /// the deadlines are whole seconds, and floating point carries them without error
    /// far beyond any plausible request timeout.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
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
    /// Returns **which** window elapsed together with the progress it was chosen
    /// against, decided in one locked read. Reading them separately - the window here,
    /// the progress again when the error is built - leaves a gap a single chunk can
    /// fall into, and the report then says "the model produced output and then stopped"
    /// about a model that produced nothing at all.
    func elapsedDeadline(first: Duration, then subsequent: Duration) -> ElapsedStreamDeadline? {
        lock.withLock {
            let window = started ? subsequent : first
            guard ContinuousClock.now - last > window else { return nil }
            // `started` is read once, above. The answer leaves with the window chosen on
            // the strength of it; nothing downstream may ask again.
            return ElapsedStreamDeadline(after: window, hadAdvanced: started)
        }
    }
}

/// What a deadline ended up measuring, as one immutable answer.
///
/// The two fields are only meaningful together: the window is chosen by whether output
/// had arrived, so a caller that takes one without the other can describe a wait that
/// never happened. A value type makes that impossible rather than merely discouraged -
/// there is no second read to get a different answer from.
struct ElapsedStreamDeadline: Sendable, Equatable {
    /// Which deadline elapsed: the wait for the first event, or the wait between two.
    var after: Duration
    /// Whether output had arrived at the moment that window was chosen.
    var hadAdvanced: Bool
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
        onTimeout: @escaping @Sendable (ElapsedStreamDeadline) -> Void,
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
