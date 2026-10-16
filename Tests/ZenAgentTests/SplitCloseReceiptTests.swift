import UIKit
import GRDB
import Testing
@testable import ZenAgent

@Suite("Native Single closure receipts", .serialized)
@MainActor
struct SplitCloseReceiptTests {
    @Test(arguments: [SplitDropSlot.top, .bottom])
    func onlySurvivorFinalLayoutCanFinishTheReadingLease(keeping: SplitDropSlot) async throws {
        let fixture = try AppShellWiringTests().makeFixture(seed: .active)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        let model = fixture.model
        try fixture.store.database.write { db in
            try Fixtures.conversation(id: "receipt-secondary").insert(db)
        }
        #expect(model.commitSplitDrop(SplitDropIntent(conversationID: model.conversationID, slot: .top)))
        #expect(await model.openInSplit(id: "receipt-secondary"))
        let source = try #require(model.pane)
        let secondary = try #require(model.splitPane)
        let initial = ScrollGeometry(viewportHeight: 300, contentHeight: 1200, offset: 900)
        for pane in [source, secondary] { pane.scrollBridge.publishViewport(initial, bottomReferenceTurn: nil) }
        let resize = SplitResizeController()
        #expect(resize.begin(model: model, minimumRatio: 0.2))
        resize.close(model: model, keeping: keeping)
        let survivor = try #require(model.pane)
        #expect(survivor === (keeping == .top ? source : secondary))
        #expect(model.splitWorkspace == nil && resize.isClosing && resize.isActive)
        let window = NSObject()
        let oldWindow = NSObject()
        let host = NSObject()
        let target = CGRect(x: 0, y: 0, width: 402, height: 874)
        let context = WorkspaceLayoutContext(windowID: ObjectIdentifier(window), windowSize: target.size,
            frame: target, isPad: false)
        let wrongSlot: WorkspaceSurfaceSlot = model.sourceSurfaceSlot == .primary ? .secondary : .primary
        let final = WorkspaceNativeLayoutReceipt(hostID: ObjectIdentifier(host), windowID: ObjectIdentifier(window), frame: target)
        resize.nativeLayout(final, context: context, slot: wrongSlot, model: model)
        resize.nativeLayout(.init(hostID: final.hostID, windowID: ObjectIdentifier(oldWindow), frame: target),
            context: context, slot: model.sourceSurfaceSlot, model: model)
        resize.nativeLayout(.init(hostID: final.hostID, windowID: final.windowID,
            frame: CGRect(x: 0, y: 0, width: 402, height: 600)),
            context: context, slot: model.sourceSurfaceSlot, model: model)
        #expect(survivor.scrollBridge.dividerFinalRevision == nil)
        resize.nativeLayout(final, context: context, slot: model.sourceSurfaceSlot, model: model)
        let revision = model.workspaceLayoutRevision
        #expect(survivor.scrollBridge.dividerFinalRevision == revision)
        #expect(resize.isActive && survivor.scrollBridge.hasDividerLease,
            "a layout receipt alone must not release unacknowledged reading restoration")
        resize.nativeLayout(final, context: context, slot: model.sourceSurfaceSlot, model: model)
        #expect(model.workspaceLayoutRevision == revision)
        let geometry = ScrollGeometry(viewportHeight: 800, contentHeight: 1200, offset: 400)
        survivor.scrollBridge.continueDividerResize(geometry: geometry, turnTops: [:], revision: revision)
        if let request = survivor.scrollRequest {
            _ = survivor.updateReading(.programmaticScrolled(geometry: geometry))
            survivor.markScrollApplied(sequence: request.sequence)
        }
        survivor.scrollBridge.acknowledgeDividerResize(revision: revision, geometry: geometry)
        #expect(!resize.isActive && !survivor.scrollBridge.hasDividerLease)
    }
}
