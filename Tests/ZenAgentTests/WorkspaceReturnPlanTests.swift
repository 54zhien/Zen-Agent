import UIKit
import Testing
@testable import ZenAgent

@Suite("Workspace cross-owner Return plan")
struct WorkspaceReturnPlanTests {
    @Test("a selected occupied owner keeps its physical host across preparation and device layout",
          arguments: [WorkspaceSurfaceSlot.primary, .secondary])
    func occupiedOtherOwnsItsReturnDestination(sourceSurface: WorkspaceSurfaceSlot) throws {
        var split = SplitWorkspaceState(sourceConversationID: "source", sourceSlot: .top)
        _ = split.occupy("other")
        split.setRatio(0.63)
        let origin = sourceSurface.other
        let phoneLandscape = WorkspaceReturnPlan.resolve(split: split, sourceSurfaceSlot: sourceSurface,
            originSlot: origin, selectedID: "source", presentation: .landscapeSingle(.bottom))
        #expect(phoneLandscape.originSlot == origin)
        #expect(phoneLandscape.targetSurfaceSlot == sourceSurface)
        #expect(phoneLandscape.targetLogicalSlot == .top)
        #expect(phoneLandscape.holdsPreviewThroughReturn)
        let size = CGSize(width: 800, height: 400)
        #expect(phoneLandscape.destination(size: size, safeArea: .zero) == CGRect(origin: .zero, size: size))

        let portrait = WorkspaceReturnPlan.resolve(split: split, sourceSurfaceSlot: sourceSurface,
            originSlot: origin, selectedID: "source", presentation: .split(.topBottom))
        let layout = try #require(SplitWorkspaceGeometry(size: CGSize(width: 400, height: 800),
            safeArea: .zero, ratio: 0.63))
        #expect(portrait.destination(size: CGSize(width: 400, height: 800), safeArea: .zero) == layout.top)
        #expect(portrait.targetSurfaceSlot == sourceSurface && portrait.holdsPreviewThroughReturn)

        let replacement = WorkspaceReturnPlan.resolve(split: split, sourceSurfaceSlot: sourceSurface,
            originSlot: origin, selectedID: "replacement", presentation: .split(.topBottom))
        #expect(replacement.targetSurfaceSlot == origin && replacement.targetLogicalSlot == .bottom)
        #expect(!replacement.holdsPreviewThroughReturn)
    }

    @Test func deletedArrangementReturnsToTheInitiatingSingleHost() {
        let plan = WorkspaceReturnPlan.resolve(split: nil, sourceSurfaceSlot: .primary,
            originSlot: .secondary, selectedID: "survivor", presentation: .single)
        #expect(plan.targetSurfaceSlot == .secondary && plan.targetLogicalSlot == nil)
        #expect(!plan.holdsPreviewThroughReturn)
    }

    @Test func returnRespectsTheEmbeddedWorkspaceWindowFrame() throws {
        var split = SplitWorkspaceState(sourceConversationID: "source", sourceSlot: .top)
        _ = split.occupy("other")
        split.setRatio(0.63)
        let rootFrame = CGRect(x: 10, y: 100, width: 400, height: 700)
        let safe = UIEdgeInsets(top: 20, left: 30, bottom: 25, right: 40)
        let plan = WorkspaceReturnPlan.resolve(split: split, sourceSurfaceSlot: .primary,
            originSlot: .secondary, selectedID: "source", presentation: .split(.topBottom))
        let geometry = try #require(SplitWorkspaceGeometry(size: rootFrame.size,
            safeArea: safe, ratio: 0.63))
        #expect(plan.destination(in: rootFrame, safeArea: safe)
            == geometry.top.offsetBy(dx: rootFrame.minX, dy: rootFrame.minY))

        let landscape = WorkspaceReturnPlan.resolve(split: split, sourceSurfaceSlot: .primary,
            originSlot: .secondary, selectedID: "source", presentation: .landscapeSingle(.bottom))
        #expect(landscape.destination(in: rootFrame, safeArea: safe) == rootFrame)
    }

    @Test func padReturnUsesTheSavedHorizontalRatioAndLogicalOwner() throws {
        var split = SplitWorkspaceState(sourceConversationID: "right-owner", sourceSlot: .bottom)
        _ = split.occupy("left-owner")
        split.selectAxis(.leftRight)
        split.setRatio(0.42)
        let plan = WorkspaceReturnPlan.resolve(split: split, sourceSurfaceSlot: .primary,
            originSlot: .primary, selectedID: "left-owner", presentation: .split(.leftRight))
        let size = CGSize(width: 1200, height: 800)
        let safe = UIEdgeInsets(top: 20, left: 30, bottom: 25, right: 40)
        let geometry = try #require(SplitWorkspaceGeometry(size: size, safeArea: safe,
            ratio: 0.42, axis: .leftRight))
        #expect(plan.targetSurfaceSlot == .secondary && plan.targetLogicalSlot == .top)
        #expect(plan.holdsPreviewThroughReturn)
        #expect(plan.destination(size: size, safeArea: safe) == geometry.top)
        #expect(split.sourceConversationID == "right-owner" && split.activeRatio == 0.42)
    }
}
