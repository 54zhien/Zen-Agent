import Foundation

/// A one-shot signal that **cannot be lost to ordering**.
///
/// The first version of the mid-stream failure test registered its handler when the
/// last chunk had been delivered, and fired it from the consumer. Those two can happen
/// in either order, and when the fire came first the lookup found nothing, the signal
/// vanished, and the test hung until the three-minute timeout — with a hang that looked
/// exactly like the behaviour being investigated.
///
/// So this is level-triggered: a request that arrives before the handler is remembered
/// and runs the moment one is installed, and a request that arrives after runs
/// immediately. Neither order is a special case.
///
/// **The handler is always dispatched, never invoked inline.** Its caller is the
/// consuming task, standing inside its own read loop; calling into `URLSession`'s
/// callback machinery from that thread leaves the failure waiting on the very loop that
/// is waiting for the failure.
final class FailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var requested = false

    init() {}

    func install(_ handler: @escaping @Sendable () -> Void) {
        let alreadyRequested: Bool = lock.withLock {
            self.handler = handler
            let pending = requested
            requested = false
            return pending
        }
        if alreadyRequested { Self.fire(handler) }
    }

    func requestFailure() {
        let ready: (@Sendable () -> Void)? = lock.withLock {
            guard let handler else {
                requested = true
                return nil
            }
            return handler
        }
        if let ready { Self.fire(ready) }
    }

    private static func fire(_ handler: @escaping @Sendable () -> Void) {
        DispatchQueue.global().async(execute: handler)
    }
}

/// Whether something has happened yet, readable from another task.
///
/// Used for readiness in tests that must not cancel before the thing they are testing
/// has actually started. A fixed sleep answers "how long has it been", which is not the
/// question — and answered it wrongly twice.
final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    init() {}

    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}
