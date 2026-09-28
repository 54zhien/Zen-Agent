import UIKit
import Testing
@testable import ZenAgent

@Suite("Lift geometry and continuous crop")
struct SurfaceLiftGeometryTests {
    @Test func literalTargetPreservesAspectAndMeetsExactCardBoundary() throws {
        let size = CGSize(width: 400, height: 800)
        let safe = UIEdgeInsets(top: 10, left: 20, bottom: 30, right: 40)
        let card = CGRect(x: 71, y: 108.8, width: 278.8, height: 562.4)
        let pose = try #require(SurfaceLiftGeometry.targetPose(size: size, safeArea: safe,
                                                             card: card, cornerRadius: 24))
        #expect(abs(pose.scale - 0.703) < 0.000001)
        #expect(abs(pose.translation.width - 10.4 / 340) < 0.000001)
        #expect(abs(pose.translation.height + 10.0 / 760) < 0.000001)
        #expect(abs(pose.cornerRadius * pose.scale - 24) < 0.000001)
        for progress in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            let presentation = try #require(SurfaceGeometry.resolve(size: size, safeArea: safe,
                request: .init(to: pose, progress: progress)))
            #expect(presentation.scale > 0 && presentation.scale <= 1)
            #expect(presentation.clipFraction.width > 0 && presentation.clipFraction.width <= 1)
            #expect(presentation.clipFraction.height > 0 && presentation.clipFraction.height <= 1)
            let width = size.width * presentation.clipFraction.width * presentation.scale
            let height = size.height * presentation.clipFraction.height * presentation.scale
            if progress == 0 { #expect(width == 400 && height == 800) }
            if progress == 1 {
                #expect(abs(width - card.width) < 0.000001)
                #expect(abs(height - card.height) < 0.000001)
                #expect(abs(size.width / 2 + presentation.translation.width - card.midX) < 0.000001)
                #expect(abs(size.height / 2 + presentation.translation.height - card.midY) < 0.000001)
            }
        }
    }

    @Test func cropInterpolatesAndInvalidCropRejectsAtomically() throws {
        var target = SurfaceGeometry.Pose(scale: 0.75, translation: .zero, cornerRadius: 24)
        target.clipFraction = CGSize(width: 0.8, height: 0.65)
        let mid = try #require(SurfaceGeometry.resolve(size: CGSize(width: 400, height: 800),
            safeArea: .zero, request: .init(to: target, progress: 0.5)))
        #expect(abs(mid.clipFraction.width - 0.9) < 0.000001)
        #expect(abs(mid.clipFraction.height - 0.825) < 0.000001)
        for invalid in [CGSize(width: 0, height: 1), CGSize(width: 1.1, height: 1),
                        CGSize(width: CGFloat.nan, height: 1), CGSize(width: 1, height: CGFloat.infinity)] {
            var bad = target
            bad.clipFraction = invalid
            #expect(SurfaceGeometry.resolve(size: CGSize(width: 400, height: 800), safeArea: .zero,
                request: .init(to: bad, progress: 1)) == nil)
        }
    }

    @Test func invalidTargetDoesNotFabricateFull() {
        let size = CGSize(width: 400, height: 800)
        let valid = CGRect(x: 20, y: 40, width: 300, height: 600)
        #expect(SurfaceLiftGeometry.targetPose(size: .zero, safeArea: .zero, card: valid, cornerRadius: 24) == nil)
        #expect(SurfaceLiftGeometry.targetPose(size: size, safeArea: .zero, card: .zero, cornerRadius: 24) == nil)
        #expect(SurfaceLiftGeometry.targetPose(size: size, safeArea: .zero,
            card: CGRect(x: -1, y: 40, width: 300, height: 600), cornerRadius: 24) == nil)
        #expect(SurfaceLiftGeometry.targetPose(size: size,
            safeArea: UIEdgeInsets(top: 800, left: 0, bottom: 0, right: 0), card: valid, cornerRadius: 24) == nil)
        #expect(SurfaceLiftGeometry.targetPose(size: size, safeArea: .zero, card: valid, cornerRadius: .nan) == nil)
        #expect(SurfaceLiftGeometry.targetPose(size: size, safeArea: .zero, card: valid, cornerRadius: 200) == nil)
    }
}
