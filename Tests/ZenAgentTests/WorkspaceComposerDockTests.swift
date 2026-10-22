import Testing
import UIKit
import SwiftUI
@testable import ZenAgent

@Suite("Shared Composer native lifecycle", .serialized)
@MainActor
struct WorkspaceComposerDockTests {
    @Test func keyboardMenuReservesOnlyTheUnavoidedOuterProposal() {
        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer()
        dock.configure(container: container, activeID: "source", visible: true)
        dock.menuTopChanged(539, ownerID: "source")
        #expect(dock.menuOverlap(in: CGRect(x: 0, y: 0, width: 402, height: 874)) == 335)
        #expect(dock.menuOverlap(in: CGRect(x: 0, y: 0, width: 402, height: 539)) == 0)
        #expect(dock.menuOverlap(in: CGRect(x: 0, y: 0, width: 402, height: 650)) == 111)
        dock.menuTopChanged(100, ownerID: "stale")
        #expect(dock.menuTop == 539)
        dock.configure(container: container, activeID: "other", visible: true)
        #expect(dock.menuOverlap(in: CGRect(x: 0, y: 0, width: 402, height: 874)) == 0)
    }

    @Test("Dock outlines paint above the editor without adding an accessibility or hit-test view")
    func outlinesAreNativeLayersAboveRetainedEditor() throws {
        let container = ComposerDockContainer(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let portal = ComposerHostPortal(frame: container.bounds)
        container.install(portal)
        let views = container.subviews
        let frame = CGRect(x: 0, y: 440, width: 402, height: 434)
        let radii = SurfaceCornerRadii(topLeft: 24, topRight: 24, bottomLeft: 62, bottomRight: 62)
        container.updateOutlines([.init(frame: frame, radii: radii, opacity: 0.9)], animated: false)
        let outline = try #require(container.layer.sublayers?.last as? CAShapeLayer)
        #expect(container.subviews == views)
        #expect(outline.name == "zen-dock-page-outline")
        #expect(outline.frame == frame)
        #expect(outline.fillColor == nil)
        #expect(outline.lineWidth == SidebarSurfaceDecoration.outlineWidth)
        #expect(outline.path?.boundingBoxOfPath == CGRect(origin: .zero, size: frame.size)
            .insetBy(dx: outline.lineWidth / 2, dy: outline.lineWidth / 2))
        #expect(abs(outline.opacity - 0.9) < 0.001)
        let next = ComposerHostPortal(frame: container.bounds)
        container.install(next)
        #expect(container.layer.sublayers?.last === outline,
                "Reparenting an editor must keep the border above its bottom fade")
        #expect(next.composer.superview === container)
        container.updateOutlines([], animated: false)
        #expect(outline.superlayer == nil)
        #expect(next.composer.superview === container)
    }

    @Test("both bottom-reaching Panes keep separate outlines through sidebar progress")
    func outlineProgressDoesNotChangeGeometryOrEditorOwnership() throws {
        let container = ComposerDockContainer(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        let radii = SurfaceCornerRadii(uniform: 24, corners: [.layerMinXMinYCorner, .layerMinXMaxYCorner])
        let frames = [CGRect(x: 0, y: 0, width: 434, height: 402),
                      CGRect(x: 440, y: 0, width: 434, height: 402)]
        for progress in [CGFloat(0), 0.4, 1, 0] {
            container.updateOutlines(frames.map { .init(frame: $0, radii: radii, opacity: progress) }, animated: false)
            let layers = try #require(container.layer.sublayers?.compactMap { $0 as? CAShapeLayer })
            #expect(layers.count == 2)
            #expect(layers.map(\.frame) == frames)
            #expect(layers.allSatisfy { abs(CGFloat($0.opacity) - progress) < 0.001 })
            #expect(container.subviews.isEmpty)
        }
    }

    @Test("a lifted native Surface keeps its Composer layout in source coordinates")
    func visualSurfacePoseDoesNotMoveTheHiddenKeyboardAnchor() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = ConversationSurfaceViewController(content: Color.clear)
        let driver = SurfaceLiftController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            driver.unbind(host); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        host.view.layoutIfNeeded()
        driver.bind(host)
        let composer = ComposerHostView(frame: host.surfaceView.convert(
            host.view.safeAreaLayoutGuide.layoutFrame, from: host.view))
        host.surfaceView.addSubview(composer)
        var config = configuration(text: "source coordinates", editing: false)
        config.liftInteraction = .init(driver: driver, conversationID: "source-layout", eligibility: { $0 })
        composer.configure(config); composer.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        composer.frame = host.surfaceView.convert(host.view.safeAreaLayoutGuide.layoutFrame, from: host.view)
        host.view.layoutIfNeeded(); composer.layoutIfNeeded()
        try #require(composer.nativeLiftInput.allowsLift)
        let original = composer.surfaceFrame
        let gap = composer.keyboardGap
        let generation = composer.motionGeneration
        try #require(driver.arm(composer.nativeLiftInput))
        try #require(driver.drag(upwardDistance: 80, eligibility: composer.nativeLiftInput))
        try #require(!host.surfaceView.transform.isIdentity)
        print("NATIVE_LIFT_ANCHOR original=\(original);frame=\(composer.surfaceFrame);beforeGap=\(gap);gap=\(composer.keyboardGap);input=\(composer.nativeLiftInput)")
        #expect(composer.surfaceFrame == original)
        #expect(composer.motionGeneration == generation)
        #expect(abs(composer.keyboardGap - gap) <= 0.5)
        #expect(composer.nativeLiftInput.composerSettled)
        #expect(!composer.nativeLiftInput.keyboardVisible)
        // Exercise the same bridge refresh that rejected the real first drag.
        composer.configure(config)
        #expect(driver.state.phase == .lifting)
        #expect(composer.editor.text == "source coordinates")
    }

    @Test("temporary unmounted Composer readiness preserves Return preparation; explicit cancellation still wins",
          arguments: [false, true])
    func returnPreparationSurvivesDetachedComposer(explicitCancellation: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = ConversationSurfaceViewController(content: Text("prepared Return"))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let driver = SurfaceLiftController()
        let gate = ReturnReadinessGate()
        var preview = false, prepared = false
        var commits = 0, cancellations = 0
        defer {
            gate.release(); driver.unbind(host)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        driver.bind(host)
        driver.configurePreview(enter: { preview = true; return true }, prepare: {
            await gate.wait()
            guard !Task.isCancelled else { return false }
            prepared = true
            return true
        }, commit: {
            commits += 1; prepared = false; preview = false
            return true
        }, cancel: { cancellations += 1; prepared = false }, isPresented: { preview }, label: { "Return" })
        driver.configureReturnDestination { size, _ in CGRect(origin: .zero, size: size) }
        let composer = ComposerHostView(frame: host.view.bounds)
        host.view.addSubview(composer)
        var config = configuration(text: "retained draft", editing: false)
        config.liftInteraction = .init(driver: driver, conversationID: "prepared-return", eligibility: { $0 })
        composer.configure(config); composer.layoutIfNeeded()
        try #require(driver.arm(SurfaceLiftEligibility()))
        try #require(driver.drag(upwardDistance: 220, eligibility: SurfaceLiftEligibility()))
        try #require(driver.end(animated: false)?.destination == .card)
        try #require(driver.returnToFull(animated: false))
        await gate.waitUntilStarted()
        let task = try #require(driver.returnTaskForTesting)
        try #require(driver.isPreparingReturn && driver.state.phase == .card)
        let before = cancellations
        composer.removeFromSuperview()
        try #require(composer.window == nil && !composer.nativeLiftInput.composerSettled)
        composer.configure(config)
        #expect(driver.isPreparingReturn && driver.state.phase == .card)
        #expect(cancellations == before && !prepared && commits == 0)
        if explicitCancellation {
            driver.invalidate()
            #expect(!driver.isPreparingReturn && driver.state.phase == .card)
            #expect(cancellations == before + 1 && !prepared)
        }
        gate.release()
        await task.value
        #expect(commits == (explicitCancellation ? 0 : 1))
        if explicitCancellation {
            #expect(driver.state.phase == .card && driver.state.pendingSettlement == nil)
        } else {
            // Preparation completes before the native viewport handoff task.
            #expect(driver.state.phase == .full
                || (driver.state.phase == .settling && driver.state.pendingSettlement?.destination == .full))
        }
        #expect(preview == explicitCancellation && !prepared)
        #expect(composer.editor.text == "retained draft")
    }

    @Test("hidden window keyboard guide safe area must not block Lift in a zero-inset bridge")
    func hiddenKeyboardWithZeroLocalInsetsRemainsLiftEligible() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)
        // A visible child wholly inside its parent's safe area has genuinely
        // zero UIKit insets. SwiftUI safeAreaRegions alone does not establish
        // that native precondition for the representable's Composer.
        let bridge = UIHostingController(rootView: ComposerHostBridge(
            configuration: configuration(text: "hidden keyboard", editing: false), focusRequested: { false }))
        root.addChild(bridge)
        root.view.addSubview(bridge.view)
        bridge.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bridge.view.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor),
            bridge.view.bottomAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.bottomAnchor),
            bridge.view.leadingAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.leadingAnchor),
            bridge.view.trailingAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.trailingAnchor)
        ])
        bridge.didMove(toParent: root)
        func portal(in view: UIView) -> ComposerHostPortal? {
            if let value = view as? ComposerHostPortal { return value }
            return view.subviews.lazy.compactMap { portal(in: $0) }.first
        }
        var native: ComposerHostPortal?
        for _ in 0..<40 where native == nil {
            root.view.layoutIfNeeded()
            native = portal(in: root.view)
            if native == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        let composer = try #require(native?.composer)
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded(); composer.layoutIfNeeded()
        try #require(window.safeAreaInsets.bottom > 0 && composer.safeAreaInsets.bottom == 0)
        try #require(root.view.keyboardLayoutGuide.layoutFrame.maxY > 0)
        try #require(root.view.keyboardLayoutGuide.layoutFrame.height <= root.view.safeAreaInsets.bottom + 1)
        #expect(!composer.nativeLiftInput.keyboardVisible)
        #expect(composer.nativeLiftInput.allowsLift)
    }

    @Test("surviving editor returns from Dock without turning native relocation into blur", arguments: [false, true], [false, true])
    func focusedSurvivorReturnsToPortal(dockFirst: Bool, explicitBlur: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)
        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let portal = ComposerHostPortal(frame: root.view.bounds)
        let owner = ComposerController(configuration: nil)
        owner.draft.text = "surviving draft"
        _ = owner.handle(.textAreaTapped)
        root.view.addSubview(portal); root.view.addSubview(container)
        dock.configure(container: container, activeID: "survivor", visible: true)
        func update(usesDock: Bool) {
            portal.update(configuration: configuration(text: owner.draft.text,
                editing: owner.draft.presentationState == .editing, onFocus: { focused in
                    _ = owner.handle(focused ? .textAreaTapped : .keyboardDismissed)
                }), focusRequested: { owner.draft.presentationState == .editing },
                suppressed: false, ownerID: "survivor", usesDock: usesDock, dock: dock)
        }
        update(usesDock: true)
        try await Task.sleep(for: .milliseconds(250))
        try #require(portal.composer.editor.isFirstResponder)
        let editor = portal.composer.editor
        if explicitBlur { _ = owner.handle(.conversationBackgroundTapped) }
        if dockFirst { dock.configure(container: container, activeID: "survivor", visible: false, returnsToPortals: true) }
        update(usesDock: false)
        if !dockFirst { dock.configure(container: container, activeID: "survivor", visible: false, returnsToPortals: true) }
        #expect(portal.composer.superview === portal)
        #expect(editor === portal.composer.editor && editor.text == "surviving draft")
        #expect(editor.isFirstResponder == !explicitBlur)
        #expect((owner.draft.presentationState == .editing) == !explicitBlur)
        try await Task.sleep(for: .milliseconds(250))
        #expect(editor.isFirstResponder == !explicitBlur)
    }

    @Test("A parked resting Composer restores its window endpoint before the next input")
    func parkedConfigurationRestoresWindowEndpoint() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        root.view.layoutIfNeeded()
        let composer = ComposerHostView(frame: root.view.bounds)
        root.view.addSubview(composer)
        let resting = configuration(text: "parked draft", editing: false)
        composer.configure(resting)
        composer.layoutIfNeeded()
        let original = composer.surfaceFrame
        let editor = composer.editor
        try #require(composer.nativeLiftInput.composerSettled)

        // The bridge configures a parked portal before register/install mounts
        // it again. Its window-dependent endpoint must be recomputed on attach.
        composer.removeFromSuperview()
        try #require(composer.window == nil)
        composer.configure(resting)
        root.view.addSubview(composer)
        composer.layoutIfNeeded()
        #expect(composer.surfaceFrame == original,
                "reattaching the same resting owner must not leave its detached fallback endpoint")
        #expect(composer.nativeLiftInput.composerSettled)
        #expect(composer.editor === editor && composer.editor.text == "parked draft")

        // The surviving secondary first returns through a short manually
        // framed portal, which later expands to Single without changing owner.
        let portal = UIView(frame: CGRect(x: 0, y: root.view.bounds.midY,
            width: root.view.bounds.width, height: root.view.bounds.height / 2))
        root.view.addSubview(portal)
        composer.frame = portal.bounds
        portal.addSubview(composer)
        composer.layoutIfNeeded()
        portal.frame = root.view.bounds
        composer.frame = portal.bounds
        composer.layoutIfNeeded()
        #expect(composer.surfaceFrame == original)
        #expect(composer.nativeLiftInput.composerSettled)
        #expect(composer.editor === editor && composer.editor.text == "parked draft")

        // A same-size reparent changes coordinates without a size callback or
        // keyboard notification. Its window-aligned endpoint must still update.
        let translated = UIView(frame: root.view.bounds.offsetBy(dx: 0, dy: 40))
        root.view.addSubview(translated)
        composer.frame = translated.bounds
        translated.addSubview(composer)
        composer.layoutIfNeeded()
        #expect(composer.surfaceFrame.offsetBy(dx: 0, dy: 40) == original)
        #expect(composer.nativeLiftInput.composerSettled)
        #expect(composer.editor === editor && composer.editor.text == "parked draft")
    }

    @Test func parkedEditorReceivesKeyboardDismissalFromItsWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // This observes screen-scoped notifications, not native focus. Keep the
        // fixture attached to a Window without starting a scene/key transition.
        let window = UIWindow(windowScene: scene)
        let surface = UIView(frame: window.bounds)
        let editor = UITextView()
        window.addSubview(surface); surface.addSubview(editor)
        let interaction = ComposerLiftInteraction(surface: surface, editor: editor) { SurfaceLiftEligibility() }
        let visible = window.convert(CGRect(x: 0, y: window.bounds.height - 300,
            width: window.bounds.width, height: 300), to: window.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: window.screen,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: visible])
        #expect(interaction.keyboardVisible)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: window.screen,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: visible])
        #expect(interaction.keyboardTransitioning)
        surface.removeFromSuperview()
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: window.screen)
        window.addSubview(surface)
        #expect(!interaction.keyboardVisible)
        #expect(!interaction.keyboardTransitioning)
    }

    @Test(arguments: [false, true])
    func focusIntentSurvivesOutgoingThenIncomingThenDockUpdateOrder(preserveOutgoing: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        // A newly keyed Window can still be completing its root appearance.
        // Drive focus only after UIKit has finished that initial transition.
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)
        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let a = ComposerHostPortal(frame: root.view.bounds), b = ComposerHostPortal(frame: root.view.bounds)
        root.view.addSubview(a); root.view.addSubview(b); root.view.addSubview(container)
        let loss = NativeFocusLossEvidence()
        let observer = NotificationCenter.default.addObserver(forName: UITextView.textDidEndEditingNotification,
            object: b.composer.editor, queue: .main) { _ in
                MainActor.assumeIsolated { loss.capture(scene: scene, window: window) }
            }
        defer { loss.armed = false; NotificationCenter.default.removeObserver(observer) }
        dock.configure(container: container, activeID: "a", visible: true)
        func update(_ portal: ComposerHostPortal, id: String, editing: Bool, active: Bool = true) {
            portal.update(configuration: configuration(text: id, editing: editing), focusRequested: { editing },
                suppressed: false, ownerID: id, usesDock: true, dock: dock, isActivePane: active)
        }
        update(a, id: "a", editing: true); update(b, id: "b", editing: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(a.composer.editor.isFirstResponder)
        update(a, id: "a", editing: false, active: !preserveOutgoing)
        if preserveOutgoing { #expect(a.composer.editor.isFirstResponder) }
        update(b, id: "b", editing: true)
        dock.configure(container: container, activeID: "b", visible: true)
        #expect(b.composer.editor.isFirstResponder, "incoming editor must receive focus at attachment")
        loss.arm()
        try await Task.sleep(for: .milliseconds(250))
        #expect(b.composer.editor.isFirstResponder, "settled focus; keyWindow=\(window.isKeyWindow), attached=\(b.composer.window === window); loss=\(loss.receipt)")
        #expect(!a.composer.editor.isFirstResponder)
        #expect(b.composer.editor.text == "b" && a.composer.editor.text == "a")
    }

    @Test("Dock refresh cannot replay a stale blur between native transfer and bridge feedback", arguments: [false, true])
    func refreshBeforeBridgeFeedbackKeepsTransferredFocus(refreshBeforeFeedback: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)

        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let a = ComposerHostPortal(frame: root.view.bounds), b = ComposerHostPortal(frame: root.view.bounds)
        let outgoing = ComposerController(configuration: nil), incoming = ComposerController(configuration: nil)
        outgoing.draft.text = "a"; incoming.draft.text = "b"
        _ = outgoing.handle(.textAreaTapped)
        root.view.addSubview(a); root.view.addSubview(b); root.view.addSubview(container)
        dock.configure(container: container, activeID: "a", visible: true)

        func update(_ portal: ComposerHostPortal, id: String, controller: ComposerController, active: Bool) {
            let editing = controller.draft.presentationState == .editing
            portal.update(configuration: configuration(text: id, editing: editing, onFocus: { focused in
                let event: ComposerPresentationEvent = focused ? .textAreaTapped : .keyboardDismissed
                _ = controller.handle(event)
            }), focusRequested: { controller.draft.presentationState == .editing }, suppressed: false, ownerID: id, usesDock: true,
                dock: dock, isActivePane: active)
        }
        update(a, id: "a", controller: outgoing, active: true)
        update(b, id: "b", controller: incoming, active: false)
        try await Task.sleep(for: .milliseconds(250))
        try #require(a.composer.editor.isFirstResponder)

        // The incoming bridge can receive the active-Pane environment before
        // the Dock's activeID update, while its draft is still resting.
        update(b, id: "b", controller: incoming, active: true)
        // Native transfer publishes .editing synchronously; SwiftUI delivers
        // that state to the portal on a later update. Refresh the same Dock in
        // that gap, without issuing a new input/blur intent from either owner.
        dock.configure(container: container, activeID: "b", visible: true)
        try #require(b.composer.editor.isFirstResponder)
        #expect(incoming.draft.presentationState == .editing)
        if refreshBeforeFeedback {
            dock.configure(container: container, activeID: "b", visible: true)
            #expect(b.composer.editor.isFirstResponder, "an unchanged Dock refresh must not replay the old resting focus request")
            #expect(incoming.draft.presentationState == .editing)
        }
        update(b, id: "b", controller: incoming, active: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(b.composer.editor.isFirstResponder)
        #expect(!a.composer.editor.isFirstResponder)
        #expect(incoming.draft.presentationState == .editing)
        #expect(a.composer.editor.text == "a" && b.composer.editor.text == "b")

        // Explicit bridge blur must still release focus after handoff.
        _ = incoming.handle(.keyboardDismissed)
        update(b, id: "b", controller: incoming, active: true)
        #expect(!b.composer.editor.isFirstResponder)
    }

    @Test("a bridge snapshot cannot undo newer native focus; a new explicit blur still applies", arguments: [false, true])
    func bridgeSnapshotAfterNativeTransfer(explicitBlur: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)
        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let a = ComposerHostPortal(frame: root.view.bounds), b = ComposerHostPortal(frame: root.view.bounds)
        let incoming = ComposerController(configuration: nil)
        incoming.draft.text = "incoming draft"
        root.view.addSubview(a); root.view.addSubview(b); root.view.addSubview(container)
        dock.configure(container: container, activeID: "a", visible: true)
        a.update(configuration: configuration(text: "outgoing draft", editing: true), focusRequested: { true },
            suppressed: false, ownerID: "a", usesDock: true, dock: dock)
        // SwiftUI can evaluate a value before UIKit transfers the responder.
        // Keep that value while the real delegate publishes the newer intent.
        let pendingConfiguration = configuration(text: incoming.draft.text, editing: false, onFocus: { focused in
            _ = incoming.handle(focused ? .textAreaTapped : .keyboardDismissed)
        })
        let pendingFocus = { incoming.draft.presentationState == .editing }
        b.update(configuration: pendingConfiguration, focusRequested: pendingFocus, suppressed: false,
            ownerID: "b", usesDock: true, dock: dock)
        try await Task.sleep(for: .milliseconds(250))
        try #require(a.composer.editor.isFirstResponder)
        dock.configure(container: container, activeID: "b", visible: true)
        try #require(b.composer.editor.isFirstResponder)
        try #require(incoming.draft.presentationState == .editing)
        // There has not yet been a bridge update containing focused=true.
        if explicitBlur { _ = incoming.handle(.conversationBackgroundTapped) }
        b.update(configuration: pendingConfiguration, focusRequested: pendingFocus, suppressed: false,
            ownerID: "b", usesDock: true, dock: dock)
        #expect(b.composer.editor.isFirstResponder == !explicitBlur,
                "a stale resting render must not issue a new keyboard-dismissal intent")
        #expect((incoming.draft.presentationState == .editing) == !explicitBlur)
        try await Task.sleep(for: .milliseconds(250))
        #expect(b.composer.editor.isFirstResponder == !explicitBlur)
        #expect(!a.composer.editor.isFirstResponder)
        #expect(b.composer.editor.text == "incoming draft" && a.composer.editor.text == "outgoing draft")
    }

    @Test("a focus request made before Dock window attachment is retried after attachment")
    func windowAttachmentRetriesPendingFocusWithoutReplayingBlur() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)

        let dock = WorkspaceComposerDockState()
        let container = ComposerDockContainer(frame: root.view.bounds)
        let portal = ComposerHostPortal(frame: root.view.bounds)
        dock.configure(container: container, activeID: "pending", visible: true)
        portal.update(configuration: configuration(text: "retained", editing: true), focusRequested: { true },
            suppressed: false, ownerID: "pending", usesDock: true, dock: dock)
        try #require(portal.composer.superview === container && portal.composer.window == nil)
        #expect(!portal.composer.editor.isFirstResponder)

        root.view.addSubview(container)
        try #require(portal.composer.window === window)
        dock.configure(container: container, activeID: "pending", visible: true)
        #expect(portal.composer.editor.isFirstResponder, "a previously unattached positive request must still be applied")
        try await Task.sleep(for: .milliseconds(250))
        #expect(portal.composer.editor.isFirstResponder)
        #expect(portal.composer.editor.text == "retained")

        portal.update(configuration: configuration(text: "retained", editing: false), focusRequested: { false },
            suppressed: false, ownerID: "pending", usesDock: true, dock: dock)
        #expect(!portal.composer.editor.isFirstResponder)
        dock.configure(container: container, activeID: "pending", visible: true)
        #expect(!portal.composer.editor.isFirstResponder)
    }

    @Test("notification-only fixture must not take key ownership from an editing window")
    func notificationFixturePreservesEditingWindow() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = ComposerDockTestRoot()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for _ in 0..<40 where !root.didAppear { try await Task.sleep(for: .milliseconds(25)) }
        try #require(root.didAppear && window.isKeyWindow)
        let editor = UITextView(frame: root.view.bounds)
        root.view.addSubview(editor)
        editor.text = "retained"
        try #require(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(250))
        try #require(editor.isFirstResponder)
        let changes = DockWindowKeyChanges()
        let observer = NotificationCenter.default.addObserver(forName: UIWindow.didResignKeyNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { changes.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        try parkedEditorReceivesKeyboardDismissalFromItsWindow()
        #expect(changes.count == 0, "a synthetic notification fixture must not replace the active editor's key window")
        #expect(window.isKeyWindow && editor.isFirstResponder)
        try await Task.sleep(for: .milliseconds(250))
        #expect(window.isKeyWindow && editor.isFirstResponder)
        #expect(editor.text == "retained")
    }

    private func configuration(text: String, editing: Bool,
                               onFocus: @escaping (Bool) -> Void = { _ in }) -> ComposerHostView.Configuration {
        .init(text: text, selection: ComposerSelection(range: 0..<0),
            state: editing ? .editing : .resting, collapseProgress: .expanded,
            font: .systemFont(ofSize: 16), showsPlus: false, primary: .send(enabled: true),
            models: [], selectedModelID: nil, errorMessage: nil, references: [],
            onRemoveQuote: { _ in }, onAcceptQuote: { _ in }, onQuotePhase: { _ in },
            onText: { _, _, _ in }, onFocus: onFocus, onSend: {}, onStop: {},
            onModel: { _ in }, onHeightChanged: { _ in })
    }
}

@MainActor
final class NativeKeyboardTransitionEvidence {
    struct Event {
        let name: Notification.Name
        let endFrame: CGRect?
    }

    private var observers: [NSObjectProtocol] = []
    private(set) var events: [Event] = []
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated { self?.events.append(Event(name: name, endFrame: frame)) }
            }
        }
    }

    func mark() -> Int { events.count }
    func events(since offset: Int) -> [Event] { Array(events.dropFirst(offset)) }

    var hasStableVisibleDidShow: Bool {
        guard let didShow = events.lastIndex(where: { $0.name == UIResponder.keyboardDidShowNotification }) else { return false }
        let afterDidShow = events.dropFirst(didShow + 1)
        guard !afterDidShow.contains(where: {
            $0.name == UIResponder.keyboardWillHideNotification || $0.name == UIResponder.keyboardDidHideNotification
        }),
        let latestFrame = events.last(where: { $0.endFrame != nil })?.endFrame else { return false }
        let localFrame = window.convert(latestFrame, from: window.screen.coordinateSpace)
        let intersection = window.bounds.intersection(localFrame)
        return !intersection.isNull && intersection.height > window.safeAreaInsets.bottom + 1
    }

    var summary: String { summary(events) }
    func summary(_ values: [Event]) -> String {
        values.map { event in
            let frame = event.endFrame.map { " frame=\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? ""
            return event.name.rawValue + frame
        }.joined(separator: "; ")
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

/// Observe only the unexpected loss, after it happens. No focus request, timer,
/// warmup or logging is added to the native transfer being checked.
@MainActor
final class NativeFocusLossEvidence {
    var armed = false
    private(set) var receipt = "no end-editing notification"
    private var expectedText: String?

    func arm(expectedText: String? = nil) {
        self.expectedText = expectedText
        receipt = "no end-editing notification"
        armed = true
    }

    func capture(scene: UIWindowScene, window: UIWindow, editor: UITextView? = nil) {
        guard armed, expectedText == nil || editor?.text == expectedText else { return }
        armed = false
        func responders(in view: UIView) -> [String] {
            (view.isFirstResponder ? ["\(type(of: view)):\(ObjectIdentifier(view))"] : [])
                + view.subviews.flatMap { responders(in: $0) }
        }
        let windows: String = scene.windows.map {
            "\(ObjectIdentifier($0)):key=\($0.isKeyWindow):hidden=\($0.isHidden):responders=\(responders(in: $0))"
        }.joined(separator: " | ")
        let stack: String = Thread.callStackSymbols.prefix(24).joined(separator: " | ")
        receipt = "time=\(ProcessInfo.processInfo.systemUptime);scene=\(scene.activationState.rawValue);key=\(window.isKeyWindow);windows=[\(windows)];stack=\(stack)"
    }
}

@MainActor
private final class ComposerDockTestRoot: UIViewController {
    private(set) var didAppear = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
    }
}

@MainActor private final class DockWindowKeyChanges { var count = 0 }

@MainActor
private final class ReturnReadinessGate {
    private var started = false
    private var released = false
    private var start: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true; start?.resume(); start = nil
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { start = $0 }
    }
    func release() {
        released = true; releaseContinuation?.resume(); releaseContinuation = nil
    }
}
