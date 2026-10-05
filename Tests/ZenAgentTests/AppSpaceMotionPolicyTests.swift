import Foundation
import Testing
@testable import ZenAgent

@Suite("App Space motion admission")
struct AppSpaceMotionPolicyTests {
    @Test("Reduce Motion retains Ink while freezing flow and parallax")
    func reducedMotionKeepsTheStaticBackground() {
        let policy = AppSpaceMotionPolicy.resolve(enabled: true, intensity: 0.5,
            offset: 100, reduceMotion: true, lowPower: false, thermal: .nominal, sceneActive: true)
        #expect(policy.showsInk)
        #expect(!policy.flows && policy.displacement == 0)
    }

    @Test("power, heat and scene inactivity freeze the same bounded renderer",
          arguments: [ProcessInfo.ThermalState.serious, .critical])
    func thermalAdmissionIsConservative(thermal: ProcessInfo.ThermalState) {
        let policy = AppSpaceMotionPolicy.resolve(enabled: true, intensity: 0.5,
            offset: 100, reduceMotion: false, lowPower: false, thermal: thermal, sceneActive: true)
        #expect(policy.showsInk && !policy.flows && policy.displacement == 0)
    }

    @Test func powerAndInactiveSceneKeepStaticInk() {
        for lowPower in [false, true] {
            let policy = AppSpaceMotionPolicy.resolve(enabled: true, intensity: 0.5,
                offset: 100, reduceMotion: false, lowPower: lowPower,
                thermal: .nominal, sceneActive: false)
            #expect(policy.showsInk && !policy.flows && policy.displacement == 0)
        }
        let policy = AppSpaceMotionPolicy.resolve(enabled: true, intensity: 0.5,
            offset: 100, reduceMotion: false, lowPower: true, thermal: .nominal, sceneActive: true)
        #expect(policy.showsInk && !policy.flows && policy.displacement == 0)
    }

    @Test("reverse parallax saturates and invalid values cannot enter a layer transform")
    func displacementIsFiniteAndBounded() {
        for offset in [-Double.infinity, -10_000, -100, 0, 100, 10_000, Double.infinity, Double.nan] {
            let policy = AppSpaceMotionPolicy.resolve(enabled: true, intensity: 1,
                offset: offset, reduceMotion: false, lowPower: false, thermal: .nominal, sceneActive: true)
            #expect(policy.displacement.isFinite && abs(policy.displacement) <= 4)
            if offset.isFinite && offset != 0 { #expect(policy.displacement * offset <= 0) }
        }
    }

    @Test func disabledInkHasNoRunningEffect() {
        let policy = AppSpaceMotionPolicy.resolve(enabled: false, intensity: 1,
            offset: 100, reduceMotion: false, lowPower: false, thermal: .nominal, sceneActive: true)
        #expect(!policy.showsInk && !policy.flows && policy.displacement == 0)
    }
}
