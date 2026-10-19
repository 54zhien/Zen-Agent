import Foundation
import Testing
@testable import ZenAgent

@Suite("App Space coast and nearest detent")
struct AppSpaceBrowseMotionTests {
    @Test func releaseKeepsMovingAndLosesSpeedBeforeChoosingTheNearestCard() {
        var motion = AppSpaceBrowseMotion(offset: 0.1, velocity: 8)
        motion.advance(deltaTime: 0.05)
        #expect(motion.offset > 0.1)
        #expect(motion.velocity > 0 && motion.velocity < 8)
        #expect(motion.target == nil)
        for _ in 0..<240 where motion.target == nil { motion.advance(deltaTime: 1.0 / 120) }
        let nearest = motion.offset.rounded()
        #expect(motion.target == nearest)
        #expect(motion.offset > 1, "A fast release must continue beyond the adjacent card")
        for _ in 0..<240 where !motion.isFinished { motion.advance(deltaTime: 1.0 / 120) }
        #expect(motion.isFinished && motion.offset == nearest && motion.velocity == 0)
    }

    @Test func slowReleaseChoosesTheNearestCard() {
        for sample in [(0.49, 0.0), (0.51, 1.0), (-0.49, 0.0), (-0.51, -1.0)] {
            var motion = AppSpaceBrowseMotion(offset: sample.0, velocity: 0)
            for _ in 0..<240 where !motion.isFinished { motion.advance(deltaTime: 1.0 / 120) }
            #expect(motion.isFinished && motion.offset == sample.1)
        }
    }

    @Test func differentDisplayRefreshRatesKeepTheSameCoastingDistance() {
        var samples: [AppSpaceBrowseMotion] = []
        for rate in [30, 60, 120] {
            var motion = AppSpaceBrowseMotion(offset: 0.15, velocity: 7)
            for _ in 0..<(rate / 5) { motion.advance(deltaTime: 1.0 / Double(rate)) }
            samples.append(motion)
        }
        for sample in samples.dropFirst() {
            #expect(abs(sample.offset - samples[0].offset) < 0.000001)
            #expect(abs(sample.velocity - samples[0].velocity) < 0.000001)
        }
    }
}
