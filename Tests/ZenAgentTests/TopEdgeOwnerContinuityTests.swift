import SwiftUI
import UIKit
import Testing
@testable import ZenAgent

@Suite("Retained Surface blur owner", .serialized)
@MainActor
struct TopEdgeOwnerContinuityTests {
    @Test("a new Pane in the same native Surface cancels and clears the previous owner's pixels")
    func replacedPaneRejectsPendingSnapshot() async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        let firstPane = try #require(model.pane)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIHostingController(rootView: WorkspaceSurfaceView(model: model) { slot in
            NewConversationView(model: model, surfaceSlot: slot)
        })
        window.rootViewController = root; window.makeKeyAndVisible()
        let gate = OwnerBlurGate()
        defer {
            gate.releaseAll()
            window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey()
        }
        var material: ConversationTopEdgeMaterial?
        for _ in 0..<40 where material == nil {
            root.view.layoutIfNeeded()
            material = visibleMaterial(in: root.view)
            if material == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        let edge = try #require(material)
        _ = UIGraphicsImageRenderer(size: root.view.bounds.size).image { _ in
            _ = root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        // Finish startup work, then hold only the test's immutable snapshot.
        edge.setWorkspaceVisible(false)
        await edge.awaitRenderForTesting()
        edge.beforeRenderForTesting = { await gate.wait() }
        edge.setWorkspaceVisible(true)
        edge.image = try #require(UIImage(systemName: "square.fill"))
        edge.refreshIfNeeded()
        let pending = try #require(edge.renderTaskForTesting)
        for _ in 0..<40 where !gate.hasWaiter { await Task.yield() }
        try #require(gate.hasWaiter)
        let source = try #require(edge.sourceIdentityForTesting)
        let frame = edge.bounds
        let count = edge.captureCount
        model.newConversation()
        let nextPane = try #require(model.pane)
        try #require(nextPane !== firstPane)
        var nativeOwnerInstalled = false
        for _ in 0..<40 where !nativeOwnerInstalled {
            root.view.layoutIfNeeded()
            nativeOwnerInstalled = containsPortal(in: root.view, ownerID: nextPane.conversationID)
            if !nativeOwnerInstalled { try await Task.sleep(for: .milliseconds(25)) }
        }
        try #require(nativeOwnerInstalled)
        #expect(visibleMaterial(in: root.view) === edge)
        #expect(edge.sourceIdentityForTesting == source && edge.window === window && edge.bounds == frame)
        #expect(pending.isCancelled, "logical Pane replacement must revoke the old capture even when native identity stays unchanged")
        #expect(edge.image == nil, "the new Pane must not keep the previous Pane's displayed strip")
        gate.releaseOne()
        await pending.value
        #expect(edge.captureCount == count, "the held previous-owner snapshot must not commit to the new Pane")
        edge.beforeRenderForTesting = nil
        gate.releaseAll()
        edge.refreshIfNeeded()
        await edge.awaitRenderForTesting()
        #expect(edge.image != nil && edge.captureCount > count)
    }

    private func visibleMaterial(in view: UIView) -> ConversationTopEdgeMaterial? {
        guard !view.isHidden, view.alpha > 0 else { return nil }
        if let edge = view as? ConversationTopEdgeMaterial, edge.bounds.height > 0 { return edge }
        return view.subviews.lazy.compactMap { visibleMaterial(in: $0) }.first
    }

    private func containsPortal(in view: UIView, ownerID: String) -> Bool {
        if let portal = view as? ComposerHostPortal, portal.ownerID == ownerID { return true }
        return view.subviews.contains { containsPortal(in: $0, ownerID: ownerID) }
    }
}

@MainActor
private final class OwnerBlurGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var hasWaiter: Bool { !waiters.isEmpty }
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
    func releaseAll() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
