import Foundation

struct AppSpaceMotionPolicy: Equatable, Sendable {
    let showsInk: Bool
    let flows: Bool
    let intensity: Double
    let displacement: Double

    static func resolve(enabled: Bool, intensity: Double, offset: Double,
                        reduceMotion: Bool, lowPower: Bool,
                        thermal: ProcessInfo.ThermalState, sceneActive: Bool) -> Self {
        let strength = intensity.isFinite ? min(1, max(0, intensity)) : 0
        let visible = enabled && strength > 0
        let motion = visible && sceneActive && !reduceMotion && !lowPower
            && (thermal == .nominal || thermal == .fair)
        // Browse supplies actual points. Slow flow is independent of this response.
        let reverse = offset.isFinite ? -min(4, max(-4, offset * 0.025)) : 0
        return Self(showsInk: visible, flows: motion, intensity: strength,
                    displacement: motion ? reverse : 0)
    }
}
