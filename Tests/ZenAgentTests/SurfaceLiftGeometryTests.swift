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

    @Test func interactivePoseTracksBothAxesAndScalesCornersWithTheComposer() throws {
        let size = CGSize(width: 400, height: 800)
        let safeArea = UIEdgeInsets(top: 10, left: 20, bottom: 30, right: 40)
        let displacement = CGSize(width: 36, height: -144)
        let windowRadius: CGFloat = 56
        let pose = try #require(SurfaceLiftGeometry.interactivePose(
            size: size, safeArea: safeArea, displacement: displacement,
            progress: 0.5, windowCornerRadius: windowRadius
        ))

        #expect(pose.scale > 0 && pose.scale < 0.84)
        #expect(pose.translation.width > 0 && pose.translation.width * 340 < displacement.width)
        #expect(pose.translation.height < 0 && pose.translation.height * 760 > displacement.height)
        #expect(abs(pose.cornerRadius - windowRadius) < 0.000001)
        #expect(pose.cornerRadius <= min(size.width, size.height) / 2)
        #expect(pose.clipFraction == CGSize(width: 1, height: 1))
    }

    @Test func longDragsStayInsideTheScreenWithIncreasingResistance() throws {
        let size = CGSize(width: 400, height: 800)
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001)
        for progress in [0.0, 0.1, 0.5, 1] {
            for displacement in [CGSize(width: 0, height: -1000), CGSize(width: 0, height: 1000),
                                 CGSize(width: -1000, height: 0), CGSize(width: 1000, height: 1000)] {
                let pose = try #require(SurfaceLiftGeometry.interactivePose(size: size,
                    safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                    displacement: displacement, progress: progress, windowCornerRadius: 62))
                let live = try #require(SurfaceGeometry.resolve(size: size,
                    safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                    request: .init(to: pose, progress: 1)))
                let card = CGRect(x: (size.width - size.width * live.scale) / 2 + live.translation.width,
                                  y: (size.height - size.height * live.scale) / 2 + live.translation.height,
                                  width: size.width * live.scale, height: size.height * live.scale)
                #expect(screen.contains(card))
                #expect(live.clipFraction == CGSize(width: 1, height: 1))
                if progress == 1 { #expect(abs(live.scale - 0.26) < 0.01) }
            }
        }
        var positions: [CGFloat] = []
        for distance in [40.0, 80, 120] {
            let pose = try #require(SurfaceLiftGeometry.interactivePose(size: size, safeArea: .zero,
                displacement: CGSize(width: 0, height: -distance), progress: 1, windowCornerRadius: 62))
            positions.append(-pose.translation.height * size.height)
        }
        #expect(positions[0] > 0 && positions[0] < 40)
        #expect(positions[1] > positions[0] && positions[2] > positions[1])
        #expect(positions[2] - positions[1] < positions[1] - positions[0])
    }

    @Test func interactiveCornerRadiusStopsAtTheSourceSurfaceBounds() throws {
        let size = CGSize(width: 30, height: 20)
        let pose = try #require(SurfaceLiftGeometry.interactivePose(
            size: size, safeArea: .zero, displacement: CGSize(width: 80, height: -80),
            progress: 1, windowCornerRadius: 60
        ))

        #expect(pose.cornerRadius == 10)
        #expect(pose.cornerRadius * pose.scale <= min(size.width, size.height) * pose.scale / 2)
    }

    @Test func scalarInteractiveGeometryScalesItsCornersWithTheSurface() throws {
        let pose = try #require(SurfaceLiftGeometry.interactivePose(
            size: CGSize(width: 400, height: 800), safeArea: .zero,
            upwardDistance: 96, progress: 0.5
        ))

        #expect(pose.scale > 0 && pose.scale < 0.84)
        #expect(abs(pose.cornerRadius - 12) < 0.000001)
        #expect(pose.translation.height < 0 && pose.translation.height > -96.0 / 800.0)
        let presentation = try #require(SurfaceGeometry.resolve(size: CGSize(width: 400, height: 800),
            safeArea: .zero, request: .init(to: pose, progress: 1)))
        #expect(presentation.translation.height < 0 && presentation.translation.height > -96)
    }
}
