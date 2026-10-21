import CoreHaptics
import UIKit

/// A soft resonant envelope, isolated from the Workspace's impact vocabulary.
/// Warm the engine asynchronously while Thinking is visible. Playback is never
/// queued behind startup, so interrupted gestures cannot produce stale feedback.
@MainActor
final class ThinkingSelectionHaptics: NSObject {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var generation = UUID()
    private var visible = false
    private var ready = false
    private var starting = false
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private let fallback = UIImpactFeedbackGenerator(style: .soft)

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(suspend),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    func prepare() {
        fallback.prepare()
    }

    func activate() {
        visible = true
        prepare()
        warmEngine()
    }

    func play() {
        guard visible, UIApplication.shared.applicationState == .active else { return }
        guard supported else { playFallback(); return }
        guard ready, let engine else {
            warmEngine()
            playFallback()
            return
        }
        do {
            try? player?.stop(atTime: CHHapticTimeImmediate)
            player = nil
            let next = try engine.makePlayer(with: Self.pattern())
            player = next
            try next.start(atTime: CHHapticTimeImmediate)
        } catch {
            // A server/audio-session failure must not poison the next selection.
            retireEngine()
            warmEngine()
            playFallback()
        }
    }

    @objc func suspend() {
        visible = false
        retireEngine()
    }

    private func warmEngine() {
        guard visible, supported, !ready, !starting,
              UIApplication.shared.applicationState == .active else { return }
        do {
            if engine == nil {
                let created = try CHHapticEngine()
                created.playsHapticsOnly = true
                // This engine belongs to the visible Thinking page. Stop it on
                // dismissal or app inactivity instead of cold-starting after an idle detent.
                created.isAutoShutdownEnabled = false
                let token = generation
                created.resetHandler = { @Sendable [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.retireEngine()
                        self.warmEngine()
                    }
                }
                created.stoppedHandler = { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        // Don't repeatedly restart during an audio interruption.
                        // The next prepare/play can start a fresh engine.
                        self.retireEngine()
                    }
                }
                engine = created
            }
            guard let engine else { return }
            let token = generation
            starting = true
            engine.start { @Sendable [weak self] error in
                let succeeded = error == nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.starting = false
                    if succeeded, self.visible, UIApplication.shared.applicationState == .active {
                        self.ready = true
                    } else {
                        self.retireEngine()
                    }
                }
            }
        } catch {
            retireEngine()
        }
    }

    private func retireEngine() {
        generation = UUID()
        ready = false
        starting = false
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        // Detach before asynchronous stop so its callbacks cannot retire a new
        // engine after a quick foreground return or a server reset.
        let retiringEngine = engine
        engine = nil
        retiringEngine?.stop(completionHandler: nil)
    }

    private func playFallback() {
        guard UIApplication.shared.applicationState == .active else { return }
        fallback.impactOccurred(intensity: 0.40)
        fallback.prepare()
    }

    private static func pattern() throws -> CHHapticPattern {
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.52),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12)
        ], relativeTime: 0, duration: 0.56)
        // Gentle amplitude ripples at the onset and tail keep the hum alive
        // without adding sharp transient impacts. The last point ends at zero.
        let envelope = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
            .init(relativeTime: 0, value: 0),
            .init(relativeTime: 0.030, value: 0.22),
            .init(relativeTime: 0.065, value: 0.12),
            .init(relativeTime: 0.105, value: 0.48),
            .init(relativeTime: 0.150, value: 0.36),
            .init(relativeTime: 0.200, value: 0.84),
            .init(relativeTime: 0.250, value: 1),
            .init(relativeTime: 0.300, value: 0.84),
            .init(relativeTime: 0.350, value: 0.64),
            .init(relativeTime: 0.400, value: 0.36),
            .init(relativeTime: 0.435, value: 0.42),
            .init(relativeTime: 0.470, value: 0.18),
            .init(relativeTime: 0.500, value: 0.24),
            .init(relativeTime: 0.530, value: 0.075),
            .init(relativeTime: 0.550, value: 0.025),
            .init(relativeTime: 0.560, value: 0)
        ], relativeTime: 0)
        return try CHHapticPattern(events: [event], parameterCurves: [envelope])
    }
}
