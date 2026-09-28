import UIKit
import Testing
@testable import ZenAgent

@Suite("Surface geometry")
struct SurfaceGeometryTests {
    private let size = CGSize(width: 400, height: 800)
    private let insets = UIEdgeInsets(top: 40, left: 10, bottom: 20, right: 10)
    private let target = SurfaceGeometry.Pose(scale: 0.6, translation: CGSize(width: 0.1, height: -0.2), cornerRadius: 24)

    @Test func endpointsClampAndReturn() throws {
        for (progress, scale, x, y, corner) in [
            (-2.0, 1.0, 0.0, 0.0, 0.0), (0, 1, 0, 0, 0),
            (0.5, 0.8, 19, -74, 12), (1, 0.6, 38, -148, 24),
            (2, 0.6, 38, -148, 24), (0.5, 0.8, 19, -74, 12), (0, 1, 0, 0, 0)
        ] {
            let result = try #require(SurfaceGeometry.resolve(size: size, safeArea: insets, request: .init(to: target, progress: progress)))
            #expect(abs(result.scale - scale) < 0.00001)
            #expect(abs(result.translation.width - x) < 0.00001)
            #expect(abs(result.translation.height - y) < 0.00001)
            #expect(abs(result.cornerRadius - corner) < 0.00001)
        }
    }

    @Test func rejectsInvalidInputsAndOverflow() {
        for progress in [CGFloat.nan, .infinity, -.infinity] {
            #expect(SurfaceGeometry.resolve(size: size, safeArea: insets, request: .init(to: target, progress: progress)) == nil)
        }
        for badSize in [CGSize.zero, CGSize(width: -1, height: 800), CGSize(width: .infinity, height: 800)] {
            #expect(SurfaceGeometry.resolve(size: badSize, safeArea: insets, request: .full) == nil)
        }
        for badPose in [
            SurfaceGeometry.Pose(scale: 0, translation: .zero, cornerRadius: 0),
            .init(scale: .nan, translation: .zero, cornerRadius: 0),
            .init(scale: 1, translation: CGSize(width: .infinity, height: 0), cornerRadius: 0),
            .init(scale: 1, translation: .zero, cornerRadius: -1),
            .init(scale: 1, translation: .zero, cornerRadius: .infinity),
            .init(scale: 1, translation: CGSize(width: .greatestFiniteMagnitude, height: 0), cornerRadius: 0)
        ] {
            #expect(SurfaceGeometry.resolve(size: size, safeArea: insets, request: .init(to: badPose, progress: 1)) == nil)
            #expect(SurfaceGeometry.resolve(size: size, safeArea: insets, request: .init(from: badPose, to: target, progress: 0)) == nil)
        }
        for badInsets in [UIEdgeInsets(top: -1, left: 0, bottom: 0, right: 0), UIEdgeInsets(top: 800, left: 0, bottom: 0, right: 0), UIEdgeInsets(top: .nan, left: 0, bottom: 0, right: 0)] {
            #expect(SurfaceGeometry.resolve(size: size, safeArea: badInsets, request: .full) == nil)
        }
    }

    @Test func usesLocalViewportAndBothEndpoints() throws {
        let from = SurfaceGeometry.Pose(scale: 0.8, translation: CGSize(width: -0.1, height: 0.1), cornerRadius: 10)
        let result = try #require(SurfaceGeometry.resolve(size: CGSize(width: 200, height: 300), safeArea: .zero, request: .init(from: from, to: target, progress: 0.5)))
        #expect(abs(result.scale - 0.7) < 0.00001)
        #expect(abs(result.translation.width) < 0.00001)
        #expect(abs(result.translation.height + 15) < 0.00001)
        #expect(result.cornerRadius == 17)
    }
}
