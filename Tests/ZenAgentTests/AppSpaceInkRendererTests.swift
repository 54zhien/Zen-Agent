import UIKit
import Testing
@testable import ZenAgent

@Suite("Bounded native Ink renderer", .serialized)
@MainActor
struct AppSpaceInkRendererTests {
    @Test("gesture samples retain native layers and independent flow animations")
    func gestureUpdatesDoNotRestartFlowOrAccumulateLayers() throws {
        let fixture = InkWindowFixture()
        defer { fixture.close() }
        fixture.view.configure(policy: policy(offset: 100), dark: true)
        let root = try #require(fixture.view.layer.sublayers?.first {
            $0.name == "zen-app-space-ink"
        })
        let gradients = (root.sublayers ?? []).compactMap { $0 as? CAGradientLayer }
        #expect(gradients.count == 2)
        let initialStarts = try gradients.map { try #require($0.animation(forKey: "zen-ink-flow")).beginTime }
        #expect(initialStarts.allSatisfy { $0 > 0 })
        for sample in -50...50 {
            fixture.view.configure(policy: policy(offset: Double(sample) * 100), dark: true)
            fixture.view.layoutIfNeeded()
            #expect(fixture.view.layer.sublayers?.filter { $0.name == "zen-app-space-ink" }.count == 1)
            #expect(root.sublayers?.count == 2)
            #expect(gradients.allSatisfy { $0.animationKeys()?.count == 1 })
            #expect(gradients.map { $0.animation(forKey: "zen-ink-flow")?.beginTime } == initialStarts.map(Optional.some))
            #expect(root.transform.m41.isFinite && abs(root.transform.m41) <= 4)
        }
        #expect(fixture.view.isOpaque)
    }

    @Test("mid-gesture motion rejection retains static Ink and clears real animation keys")
    func livePolicyAndWindowAttachmentBoundTheRenderer() throws {
        let fixture = InkWindowFixture()
        defer { fixture.close() }
        fixture.view.configure(policy: policy(offset: 100), dark: true)
        let root = try #require(fixture.view.layer.sublayers?.first { $0.name == "zen-app-space-ink" })
        let gradients = (root.sublayers ?? []).compactMap { $0 as? CAGradientLayer }
        #expect(gradients.count == 2)
        for _ in 0..<20 {
            fixture.view.configure(policy: policy(offset: 100, reduceMotion: true), dark: true)
            #expect(!root.isHidden)
            #expect(gradients.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
            #expect(root.transform.m41 == 0)
            fixture.view.configure(policy: policy(offset: 100), dark: true)
            #expect(gradients.allSatisfy { $0.animationKeys()?.count == 1 })
            fixture.view.removeFromSuperview()
            #expect(gradients.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
            fixture.container.view.addSubview(fixture.view)
            #expect(gradients.allSatisfy { $0.animationKeys()?.count == 1 })
            #expect(root.sublayers?.count == 2)
        }
        for rejected in [policy(offset: 100, lowPower: true),
                         policy(offset: 100, thermal: .serious),
                         policy(offset: 100, thermal: .critical),
                         policy(offset: 100, sceneActive: false)] {
            fixture.view.configure(policy: rejected, dark: true)
            #expect(!root.isHidden && root.transform.m41 == 0)
            #expect(gradients.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        }
    }

    @Test("light mode and disabled Ink leave an opaque static canvas")
    func lightAndDisabledPresentationHaveNoEffectWork() throws {
        let fixture = InkWindowFixture()
        defer { fixture.close() }
        fixture.view.configure(policy: policy(offset: Double.infinity), dark: true)
        let root = try #require(fixture.view.layer.sublayers?.first { $0.name == "zen-app-space-ink" })
        #expect(root.transform.m41.isFinite)
        fixture.view.configure(policy: policy(offset: 100), dark: false)
        #expect(root.isHidden && root.transform.m41 == 0)
        #expect((root.sublayers ?? []).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        fixture.view.configure(policy: .resolve(enabled: false, intensity: 0.5,
            offset: 100, reduceMotion: false, lowPower: false, thermal: .nominal, sceneActive: true), dark: true)
        #expect(root.isHidden && fixture.view.isOpaque)
        #expect((root.sublayers ?? []).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    private func policy(offset: Double, reduceMotion: Bool = false, lowPower: Bool = false,
                        thermal: ProcessInfo.ThermalState = .nominal, sceneActive: Bool = true) -> AppSpaceMotionPolicy {
        .resolve(enabled: true, intensity: 0.5, offset: offset, reduceMotion: reduceMotion,
            lowPower: lowPower, thermal: thermal, sceneActive: sceneActive)
    }
}

@MainActor
private struct InkWindowFixture {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 720))
    let container = UIViewController()
    let view = AppSpaceInkNativeView(frame: CGRect(x: 0, y: 0, width: 360, height: 720))

    init() {
        window.rootViewController = container
        container.view.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
    }

    func close() {
        view.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
    }
}
