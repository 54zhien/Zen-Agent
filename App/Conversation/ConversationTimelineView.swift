import SwiftUI

private struct ConversationTimelineViewport: Equatable {
    let geometry: ScrollGeometry
    let nativeGeometry: SwiftUI.ScrollGeometry
    let workspaceVisible: Bool
    let workspaceRevision: UInt64
    let layoutRevision: UInt64
}

private struct DividerTurnMaterialization: Equatable {
    let leaseID: UUID
    let revision: UInt64
    let runID: String
}

private struct ConversationTimelineTurnMeasurements: Equatable, Sendable {
    var viewportFrames: [String: CGRect] = [:]
    var contentTops: [String: Double] = [:]
    var layoutRevision: UInt64 = 0
}

private struct ConversationTimelineTurnFramesKey: PreferenceKey {
    static let defaultValue = ConversationTimelineTurnMeasurements()

    static func reduce(value: inout ConversationTimelineTurnMeasurements,
                       nextValue: () -> ConversationTimelineTurnMeasurements) {
        let next = nextValue()
        if next.layoutRevision > value.layoutRevision { value = next; return }
        guard next.layoutRevision == value.layoutRevision else { return }
        value.viewportFrames.merge(next.viewportFrames, uniquingKeysWith: { _, latest in latest })
        value.contentTops.merge(next.contentTops, uniquingKeysWith: { _, latest in latest })
    }
}

/// The conversation reading surface inside a reusable Pane.
///
/// The app-root choice for the first-launch / zero-conversation state remains with its host.
///
/// The turn boundary is carried by vertical rhythm rather than by a rule or a divider
/// (Blueprint 3.1): the space between Turns is much larger than the space inside one, and
/// nothing is drawn to say where a turn ends.
struct ConversationTimelineView: View {
    let projection: ConversationTimelineProjection
    let pendingToolApprovals: [ToolApprovalProjection]
    let runtime: ConversationRuntime
    var onPendingToolApprovalsChanged: @MainActor ([ToolApprovalProjection]) -> Void = { _ in }
    var onQuoteReference: (QuoteReference) -> Void = { _ in }
    var onQuoteDragPhaseChanged: (ComposerQuoteDragPhase) -> Void = { _ in }
    var onSelectionHandleDragChanged: (Bool) -> Void = { _ in }
    var onBlankBackgroundTap: () -> Void = {}
    var scrollBridge: ConversationPaneScrollBridge? = nil
    var bottomComposerClearance: CGFloat = 62

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.surfaceLiftController) private var surfaceLift
    @Environment(\.workspaceLayoutRevision) private var layoutRevision
    @State private var readingGeometryWasSuspended = false
    @State private var acceptedWorkspaceRevision: UInt64?
    @State private var measuredLayoutRevision: UInt64?
    @State private var acceptedLayoutRevision: UInt64?
    @ScaledMetric(relativeTo: .body) private var betweenTurns = Metrics.betweenTurns
    @ScaledMetric(relativeTo: .body) private var contentInset = Metrics.contentInset
    @State private var selectedApproval: ToolApprovalProjection?
    @State private var resolvingApprovalID: String?
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var latestScrollGeometry: ScrollGeometry?
    @State private var turnFrames: [String: CGRect] = [:]
    @State private var turnContentTops: [String: Double] = [:]
    @State private var materializingSequence: UInt64?
    @State private var materializationRequest: ConversationPaneScrollRequest?
    @State private var dividerMaterialization: DividerTurnMaterialization?
    @State private var latestBottomReferenceTurn: (runID: String, turnTop: Double)?
    @State private var activeScrollPhase: ScrollPhase = .idle
    @State private var pendingAppliedScroll: ConversationPaneScrollRequest?

    var body: some View {
        ScrollViewReader { proxy in
            timelineContent
                .onChange(of: materializationRequest) { _, request in
                    guard acceptsScrollRequests, let request, case .restoreAnchor(let anchor) = request.action else { return }
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) { proxy.scrollTo(anchor.runID, anchor: .top) }
                }
                .onChange(of: dividerMaterialization) { _, request in
                    guard acceptsReadingGeometry, let request,
                          scrollBridge?.dividerLeaseID == request.leaseID,
                          layoutRevision == request.revision else { return }
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) { proxy.scrollTo(request.runID, anchor: .bottom) }
                }
#if DEBUG
                .onChange(of: scrollBridge?.pane.previewReadingBootstrapForUITest) { _, runID in
                    if let runID { proxy.scrollTo(runID, anchor: .top) }
                }
#endif
        }
    }

    private var timelineContent: some View {
        let workspaceVisible = surfaceLift?.isWorkspaceVisible != false
        let workspaceRevision = surfaceLift?.workspaceVisibilityRevision ?? 0
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !conversationApprovals.isEmpty {
                    Text("需要处理的工具调用")
                        .font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                    ForEach(conversationApprovals) { approval in
                        Button {
                            selectedApproval = approval
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.raised.fill")
                                    .imageScale(.small)
                                Text(approval.toolDisplayName)
                                    .font(Typography.font(
                                        for: .interfaceBody,
                                        dynamicTypeSize: dynamicTypeSize
                                    ))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let selectedApproval {
                    ToolApprovalCardView(approval: selectedApproval,
                                         isResolving: resolvingApprovalID == selectedApproval.toolCallID) { request in
                        resolveToolApproval(request)
                    }
                    .frame(maxHeight: 280)
                    .padding(.vertical, 8)
                }
            }
            .padding(
                .horizontal,
                conversationApprovals.isEmpty && selectedApproval == nil ? 0 : contentInset
            )
            .padding(.top, conversationApprovals.isEmpty && selectedApproval == nil ? 0 : 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: betweenTurns) {
                    ForEach(projection.turns) { turn in
                        ConversationTurnView(
                            turn: turn,
                            onQuoteReference: onQuoteReference,
                            onQuoteDragPhaseChanged: onQuoteDragPhaseChanged,
                            onSelectionHandleDragChanged: onSelectionHandleDragChanged
                        )
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ConversationTimelineTurnFramesKey.self,
                                    value: ConversationTimelineTurnMeasurements(
                                        viewportFrames: [turn.runID: geometry.frame(in: .named(scrollCoordinateSpace))],
                                        contentTops: [turn.runID: Double(geometry.frame(in: .named(contentCoordinateSpace)).minY)],
                                        layoutRevision: layoutRevision
                                    )
                                )
                            }
                        }
                        .id(turn.runID)
                    }
                }
                .padding(.horizontal, contentInset)
                .padding(.vertical, betweenTurns)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: contentCoordinateSpace)
                .background {
                    // Empty timelines also need a final layout receipt.
                    Color.clear.preference(key: ConversationTimelineTurnFramesKey.self,
                        value: ConversationTimelineTurnMeasurements(layoutRevision: layoutRevision))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: bottomComposerClearance)
            }
            .coordinateSpace(name: scrollCoordinateSpace)
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
#if DEBUG
                if let scrollBridge {
                    scrollBridge.blankTapSequence &+= 1
                    scrollBridge.blankTapDiagnostic = "point=\(tap.location);blank=\(Self.isBlankTap(tap.location, turnFrames: turnFrames));frames=\(turnFrames.values)"
                }
#endif
                guard Self.isBlankTap(tap.location, turnFrames: turnFrames) else { return }
                onBlankBackgroundTap()
            })
#if DEBUG
            .onChange(of: layoutRevision, initial: true) { _, revision in
                scrollBridge?.observedLayoutDiagnostic = String(revision)
            }
#endif
            .scrollPosition($scrollPosition, anchor: .top)
            .onPreferenceChange(ConversationTimelineTurnFramesKey.self) { measurement in
                guard surfaceLift?.isWorkspaceVisible != false else { return }
                guard measurement.layoutRevision == layoutRevision else { return }
                measuredLayoutRevision = measurement.layoutRevision
                let frames = measurement.viewportFrames
                turnFrames = frames
                turnContentTops = measurement.contentTops
                // Lazy/native Turn measurements can change after scrollTo was
                // issued. The same logical request then needs a corrected target;
                // treating its sequence as already issued strands restoration.
                if let pending = pendingAppliedScroll, case .restoreAnchor(_) = pending.action {
                    pendingAppliedScroll = nil
                }
                if isWorkspaceGeometryReady, let latestScrollGeometry {
                    latestBottomReferenceTurn = bottomVisibleTurn(
                        in: frames,
                        geometry: latestScrollGeometry
                    )
                    publishDividerViewport(latestScrollGeometry)
                    if scrollBridge?.hasDividerLease == true {
                        repairDividerPosition(latestScrollGeometry)
                        return
                    }
                    if acceptsReadingGeometry, scrollBridge?.isHeightChangeActive == true {
                        scrollBridge?.continueHeightChange(
                            geometry: latestScrollGeometry,
                            turnTops: turnTops(in: frames, geometry: latestScrollGeometry)
                        )
                    }
                    applyPendingScrollIfReady()
                    publishReturnLayoutIfReady(latestScrollGeometry)
                }
            }
            .onScrollGeometryChange(for: ConversationTimelineViewport.self) { geometry in
                ConversationTimelineViewport(geometry: Self.paneGeometry(from: geometry),
                                             nativeGeometry: geometry,
                                             workspaceVisible: workspaceVisible,
                                             workspaceRevision: workspaceRevision,
                                             layoutRevision: layoutRevision)
            } action: { previous, viewport in
#if DEBUG
                scrollBridge?.nativeGeometryDiagnostic = "offset=\(viewport.nativeGeometry.contentOffset);content=\(viewport.nativeGeometry.contentSize);insets=\(viewport.nativeGeometry.contentInsets);container=\(viewport.nativeGeometry.containerSize);visible=\(viewport.nativeGeometry.visibleRect)"
#endif
                // Visibility participates in equality so mounting the same-size
                // viewport still drains Run updates held while the Pane was hidden.
                guard viewport.workspaceVisible, surfaceLift?.isWorkspaceVisible != false,
                      viewport.workspaceRevision == (surfaceLift?.workspaceVisibilityRevision ?? 0),
                      viewport.layoutRevision == layoutRevision,
                      viewport.geometry.isUsableForPane else {
                    readingGeometryWasSuspended = true
                    return
                }
                if !previous.workspaceVisible || (viewport.workspaceRevision > 0
                    && acceptedWorkspaceRevision != viewport.workspaceRevision) {
                    readingGeometryWasSuspended = true
                    activeScrollPhase = .idle
                    pendingAppliedScroll = nil
                }
                // No request/phase callback may acknowledge the retained old
                // viewport before this attachment supplies its first measurement.
                acceptedWorkspaceRevision = viewport.workspaceRevision
                if acceptedLayoutRevision != viewport.layoutRevision { pendingAppliedScroll = nil }
                acceptedLayoutRevision = viewport.layoutRevision
                handleScrollGeometryChange(viewport.geometry)
            }
            .onScrollPhaseChange { _, phase, context in
                activeScrollPhase = phase
                guard acceptsReadingGeometry else { return }
                if scrollBridge?.hasDividerLease == true {
                    if phase == .idle { scrollBridge?.endHeightChange() }
                    if let latestScrollGeometry { repairDividerPosition(latestScrollGeometry) }
                    return
                }
                switch phase {
                case .tracking, .interacting:
                    pendingAppliedScroll = nil
                    scrollBridge?.userScrolled(
                        geometry: Self.paneGeometry(from: context.geometry),
                        topVisibleTurn: topVisibleTurn(
                            in: turnFrames,
                            geometry: Self.paneGeometry(from: context.geometry)
                        )
                    )
                case .idle:
                    scrollBridge?.endHeightChange()
                    applyPendingScrollIfReady()
                case .decelerating, .animating:
                    break
                @unknown default:
                    break
                }
            }
            .onChange(of: surfaceLift?.state.phase) { _, phase in
                guard phase == .full, acceptsReadingGeometry, let scrollBridge, let latestScrollGeometry else { return }
                scrollBridge.endHeightChange()
                pendingAppliedScroll = nil
                _ = scrollBridge.pane.updateReading(.geometryChanged(geometry: latestScrollGeometry, anchor: nil))
                applyPendingScrollIfReady()
            }
            .onChange(of: scrollBridge?.pane.scrollRequest) { _, request in
                guard let request else {
                    pendingAppliedScroll = nil
                    materializingSequence = nil
                    materializationRequest = nil
                    return
                }
                if scrollBridge?.hasDividerLease == true, let latestScrollGeometry {
                    repairDividerPosition(latestScrollGeometry)
                } else {
                    applyScrollRequest(request)
                }
            }
            .onChange(of: scrollBridge?.dividerFinalRevision) { _, _ in
                if let latestScrollGeometry { repairDividerPosition(latestScrollGeometry) }
            }
            .onChange(of: scrollBridge?.dividerLeaseID) { _, _ in
                dividerMaterialization = nil
                if let latestScrollGeometry { repairDividerPosition(latestScrollGeometry) }
            }
            .onAppear {
                if selectedApproval == nil {
                    selectedApproval = conversationApprovals.first
                }
                if let request = scrollBridge?.pane.scrollRequest {
                    applyScrollRequest(request)
                }
            }
        }
        .onChange(of: conversationApprovals) { _, refreshedApprovals in
            if let selectedApproval,
               let refreshed = refreshedApprovals.first(where: {
                   $0.toolCallID == selectedApproval.toolCallID
               }) {
                self.selectedApproval = refreshed
            } else if let selectedApproval {
                self.selectedApproval = nil
            } else {
                selectedApproval = refreshedApprovals.first
            }
        }
    }

    private var scrollCoordinateSpace: String {
        "conversation-timeline-scroll-\(projection.conversationID)"
    }

    private var contentCoordinateSpace: String {
        "conversation-timeline-content-\(projection.conversationID)"
    }

    static func isBlankTap(_ location: CGPoint, turnFrames: [String: CGRect]) -> Bool {
        turnFrames.values.allSatisfy { !$0.contains(location) }
    }

    static func paneGeometry(from geometry: SwiftUI.ScrollGeometry) -> ScrollGeometry {
        ScrollGeometry(
            viewportHeight: Double(geometry.containerSize.height),
            // SwiftUI's container is already the usable viewport after insets.
            // Adding insets to content here would count them twice and make the
            // native bottom (including short/empty content) impossible to ack.
            contentHeight: Double(geometry.contentSize.height),
            offset: Double(geometry.contentOffset.y + geometry.contentInsets.top)
        )
    }

    private func handleScrollGeometryChange(_ geometry: ScrollGeometry) {
        guard surfaceLift?.isWorkspaceVisible != false else { return }
        let previousGeometry = latestScrollGeometry
        let previousBottomReferenceTurn = latestBottomReferenceTurn
        latestScrollGeometry = geometry

        guard let scrollBridge else { return }
#if DEBUG
        if ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1",
           case .reading(let anchor, _) = scrollBridge.pane.readingPosition.mode {
            print("PREVIEW_READING_GEOMETRY viewport=\(geometry.viewportHeight) offset=\(geometry.offset) turnFrame=\(String(describing: turnFrames[anchor.runID])) anchor=\(anchor.relativeViewportOffset) phase=\(String(describing: surfaceLiftPhaseForDiagnostic)) clearance=\(bottomComposerClearance)")
        }
#endif
        // Intermediate Lift/Return layout is presentation geometry. Keep the
        // Session anchor until Full and ignore its transient predecessor viewport.
        guard acceptsReadingGeometry else {
            readingGeometryWasSuspended = true
            return
        }
        publishDividerViewport(geometry)
        if scrollBridge.hasDividerLease {
            repairDividerPosition(geometry)
            return
        }
        if readingGeometryWasSuspended {
            readingGeometryWasSuspended = false
            scrollBridge.endHeightChange()
            pendingAppliedScroll = nil
            _ = scrollBridge.pane.updateReading(.geometryChanged(geometry: geometry, anchor: nil))
            applyPendingScrollIfReady()
            return
        }
        if isUserDrivenScroll {
            pendingAppliedScroll = nil
            scrollBridge.userScrolled(
                geometry: geometry,
                topVisibleTurn: topVisibleTurn(in: turnFrames, geometry: geometry)
            )
            latestBottomReferenceTurn = bottomVisibleTurn(in: turnFrames, geometry: geometry)
            return
        }

        if let previousGeometry,
           previousGeometry.viewportHeight != geometry.viewportHeight {
            if !scrollBridge.isHeightChangeActive {
                scrollBridge.beginHeightChange(
                    geometry: previousGeometry,
                    bottomReferenceTurn: previousBottomReferenceTurn
                )
            }
            scrollBridge.continueHeightChange(
                geometry: geometry,
                turnTops: turnTops(in: turnFrames, geometry: geometry)
            )
        } else if let previousGeometry,
                  previousGeometry.contentHeight != geometry.contentHeight {
            _ = scrollBridge.pane.updateReading(.geometryChanged(
                geometry: geometry,
                anchor: anchor(for: topVisibleTurn(in: turnFrames, geometry: geometry), geometry: geometry)
            ))
        }

        latestBottomReferenceTurn = bottomVisibleTurn(in: turnFrames, geometry: geometry)
        publishDividerViewport(geometry)
        acknowledgeAppliedScrollIfReady(geometry)
        applyPendingScrollIfReady()
        publishReturnLayoutIfReady(geometry)
    }

    private func publishReturnLayoutIfReady(_ geometry: ScrollGeometry) {
#if DEBUG
        scrollBridge?.timelineReceiptDiagnostic = "revision=\(layoutRevision);accepted=\(String(describing: acceptedLayoutRevision));measured=\(String(describing: measuredLayoutRevision));ready=\(acceptsReadingGeometry);viewport=\(geometry.viewportHeight)"
#endif
        guard acceptsReadingGeometry, acceptedLayoutRevision == layoutRevision,
              measuredLayoutRevision == layoutRevision, pendingAppliedScroll == nil else { return }
        scrollBridge?.publishReturnLayout(revision: layoutRevision,
            visibilityRevision: surfaceLift?.workspaceVisibilityRevision ?? 0, geometry: geometry)
    }

    private func publishDividerViewport(_ geometry: ScrollGeometry) {
        guard acceptsReadingGeometry else { return }
        let bottom = latestBottomReferenceTurn.map { reference in
            (runID: reference.runID, turnTop: turnContentTops[reference.runID] ?? reference.turnTop)
        }
        scrollBridge?.publishViewport(geometry, bottomReferenceTurn: bottom)
    }

    private func repairDividerPosition(_ geometry: ScrollGeometry) {
#if DEBUG
        scrollBridge?.timelineReceiptDiagnostic = "revision=\(layoutRevision);accepted=\(String(describing: acceptedLayoutRevision));measured=\(String(describing: measuredLayoutRevision));ready=\(acceptsReadingGeometry);viewport=\(geometry.viewportHeight)"
#endif
        guard acceptsReadingGeometry, let scrollBridge, scrollBridge.hasDividerLease,
              acceptedLayoutRevision == layoutRevision, measuredLayoutRevision == layoutRevision else { return }
        scrollBridge.continueDividerResize(geometry: geometry, turnTops: turnContentTops, revision: layoutRevision)
        if let runID = scrollBridge.dividerReferenceTurnID, turnContentTops[runID] == nil,
           let leaseID = scrollBridge.dividerLeaseID,
           projection.turns.contains(where: { $0.runID == runID }) {
            // Lazy children may leave layout while the viewport is changing.
            // Bring the retained reference into layout before precise repair.
            dividerMaterialization = DividerTurnMaterialization(leaseID: leaseID,
                revision: layoutRevision, runID: runID)
            return
        }
        dividerMaterialization = nil
        acknowledgeAppliedScrollIfReady(geometry)
        applyPendingScrollIfReady()
        scrollBridge.acknowledgeDividerResize(revision: layoutRevision, geometry: geometry)
    }

#if DEBUG
    @Environment(\.surfaceLiftController) private var surfaceLiftForDiagnostic
    private var surfaceLiftPhaseForDiagnostic: SurfaceLiftState.Phase? { surfaceLiftForDiagnostic?.state.phase }
#endif

    private var isWorkspaceGeometryReady: Bool {
        guard let surfaceLift else { return true }
        return surfaceLift.isWorkspaceVisible
            && acceptedWorkspaceRevision == surfaceLift.workspaceVisibilityRevision
    }

    private var acceptsReadingGeometry: Bool {
        isWorkspaceGeometryReady && (surfaceLift == nil || surfaceLift?.state.phase == .full)
    }

    private var acceptsScrollRequests: Bool {
        guard let surfaceLift else { return true }
        return isWorkspaceGeometryReady && (surfaceLift.state.phase == .full
            || (surfaceLift.state.phase == .settling && surfaceLift.state.pendingSettlement?.destination == .full))
    }

    private var isUserDrivenScroll: Bool {
        activeScrollPhase == .tracking
            || activeScrollPhase == .interacting
            || activeScrollPhase == .decelerating
    }

    private func topVisibleTurn(
        in frames: [String: CGRect],
        geometry: ScrollGeometry
    ) -> (runID: String, turnTop: Double)? {
        guard geometry.isUsableForPane else { return nil }
        let viewportHeight = CGFloat(geometry.viewportHeight)
        let visibleFrames = frames.filter {
            $0.value.minY < viewportHeight && $0.value.maxY > 0
        }
        guard let first = visibleFrames.min(by: { $0.value.minY < $1.value.minY }) else {
            return nil
        }
        let turnTop = Double(first.value.minY) + geometry.offset
        guard turnTop.isFinite else { return nil }
        return (runID: first.key, turnTop: turnTop)
    }

    private func bottomVisibleTurn(
        in frames: [String: CGRect],
        geometry: ScrollGeometry
    ) -> (runID: String, turnTop: Double)? {
        guard geometry.isUsableForPane else { return nil }
        let viewportHeight = CGFloat(geometry.viewportHeight)
        let visibleFrames = frames.filter {
            $0.value.minY < viewportHeight && $0.value.maxY > 0
        }
        guard let last = visibleFrames.max(by: { $0.value.minY < $1.value.minY }) else {
            return nil
        }
        let turnTop = Double(last.value.minY) + geometry.offset
        guard turnTop.isFinite else { return nil }
        return (runID: last.key, turnTop: turnTop)
    }

    private func turnTops(
        in frames: [String: CGRect],
        geometry: ScrollGeometry
    ) -> [String: Double] {
        frames.reduce(into: [:]) { result, entry in
            let turnTop = Double(entry.value.minY) + geometry.offset
            if turnTop.isFinite {
                result[entry.key] = turnTop
            }
        }
    }

    private func anchor(
        for turn: (runID: String, turnTop: Double)?,
        geometry: ScrollGeometry
    ) -> TurnAnchor? {
        guard let turn,
              geometry.isUsableForPane,
              let anchor = AnchorResolver.capture(
                runID: turn.runID,
                turnTop: turn.turnTop,
                geometry: geometry
              ),
              anchor.relativeViewportOffset.isFinite
        else { return nil }
        return anchor
    }

    private func applyScrollRequest(_ request: ConversationPaneScrollRequest) {
        guard acceptsScrollRequests, let scrollBridge,
              scrollBridge.pane.scrollRequest?.sequence == request.sequence,
              (!isUserDrivenScroll || scrollBridge.hasDividerLease),
              (!scrollBridge.hasDividerLease || (acceptedLayoutRevision == layoutRevision && measuredLayoutRevision == layoutRevision)),
              pendingAppliedScroll?.sequence != request.sequence,
              let geometry = latestScrollGeometry
        else { return }

        var restoreTarget: Double?
        if case let .restoreAnchor(turnAnchor) = request.action {
            guard let turnTop = restorationTurnTop(turnAnchor.runID, sequence: request.sequence, geometry: geometry) else {
                // Lazy children have no measured frame until they enter layout.
                // Materialize by stable Turn identity before precise offset repair.
                guard materializingSequence != request.sequence,
                      projection.turns.contains(where: { $0.runID == turnAnchor.runID }) else { return }
                materializingSequence = request.sequence
                materializationRequest = request
                return
            }
            // Content coordinates do not depend on scroll offset. Pairing a new
            // viewport frame with an older geometry callback creates a false target.
            guard let target = AnchorResolver.restoreTarget(
                    anchor: turnAnchor,
                    turnTop: turnTop,
                    geometry: geometry
                  ),
                  target.isFinite
            else { return }
            restoreTarget = clampedOffset(target, geometry: geometry)
        }

        pendingAppliedScroll = request
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            switch request.action {
            case .none:
                pendingAppliedScroll = nil
            case .scrollToBottom:
                scrollPosition.scrollTo(edge: .bottom)
            case .restoreAnchor(_):
                guard let restoreTarget else {
                    pendingAppliedScroll = nil
                    return
                }
                scrollPosition.scrollTo(y: CGFloat(restoreTarget))
            case .maintainBottomEdge(let targetOffset):
                guard targetOffset.isFinite else {
                    pendingAppliedScroll = nil
                    return
                }
                scrollPosition.scrollTo(y: CGFloat(targetOffset))
            }
        }
        acknowledgeAppliedScrollIfReady(geometry)
    }

    private func applyPendingScrollIfReady() {
        guard let request = scrollBridge?.pane.scrollRequest else { return }
        applyScrollRequest(request)
    }

    private func acknowledgeAppliedScrollIfReady(_ geometry: ScrollGeometry) {
        guard let request = pendingAppliedScroll,
              let scrollBridge,
              scrollBridge.pane.scrollRequest?.sequence == request.sequence,
              reachedTarget(for: request, geometry: geometry)
        else { return }

        pendingAppliedScroll = nil
        _ = scrollBridge.pane.updateReading(.programmaticScrolled(geometry: geometry))
        scrollBridge.pane.markScrollApplied(sequence: request.sequence)
        publishReturnLayoutIfReady(geometry)
#if DEBUG
        if ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1",
           case .reading(let anchor, _) = scrollBridge.pane.readingPosition.mode {
            scrollBridge.pane.previewReadingDiagnosticForUITest = "viewport=\(geometry.viewportHeight) offset=\(geometry.offset) turnFrame=\(String(describing: turnFrames[anchor.runID])) anchor=\(anchor.relativeViewportOffset) clearance=\(bottomComposerClearance)"
            print("PREVIEW_READING_ACK sequence=\(request.sequence) viewport=\(geometry.viewportHeight) offset=\(geometry.offset) turnFrame=\(String(describing: turnFrames[anchor.runID])) anchor=\(anchor.relativeViewportOffset) clearance=\(bottomComposerClearance)")
        }
#endif
    }

    private func restorationTurnTop(_ runID: String, sequence: UInt64, geometry: ScrollGeometry) -> Double? {
        // Missing lazy targets need a content-relative measurement after the ID jump.
        // Existing visible/keyboard restoration keeps its established transport.
        if materializingSequence == sequence { return turnContentTops[runID] }
        return turnTops(in: turnFrames, geometry: geometry)[runID]
    }

    private func reachedTarget(for request: ConversationPaneScrollRequest, geometry: ScrollGeometry) -> Bool {
        guard geometry.isUsableForPane else { return false }
        let targetOffset: Double
        switch request.action {
        case .none:
            return false
        case .scrollToBottom:
            targetOffset = max(0, geometry.contentHeight - geometry.viewportHeight)
        case .restoreAnchor(let turnAnchor):
            guard let turnTop = restorationTurnTop(turnAnchor.runID, sequence: request.sequence, geometry: geometry),
                  let target = AnchorResolver.restoreTarget(
                    anchor: turnAnchor,
                    turnTop: turnTop,
                    geometry: geometry
                  )
            else { return false }
            targetOffset = clampedOffset(target, geometry: geometry)
        case .maintainBottomEdge(let target):
            targetOffset = target
        }
        return targetOffset.isFinite && abs(geometry.offset - targetOffset) <= 0.5
    }

    private func clampedOffset(_ target: Double, geometry: ScrollGeometry) -> Double {
        let maximumOffset = max(0, geometry.contentHeight - geometry.viewportHeight)
        return max(0, min(maximumOffset, target))
    }

    private var conversationApprovals: [ToolApprovalProjection] {
        pendingToolApprovals.filter { $0.conversationID == projection.conversationID }
    }

    private func resolveToolApproval(_ request: ToolApprovalRequest) {
        guard request.conversationID == projection.conversationID,
              resolvingApprovalID == nil
        else { return }
        resolvingApprovalID = request.toolCallID

        Task { @MainActor in
            defer { resolvingApprovalID = nil }

            do {
                try await runtime.resolveToolApproval(request)
            } catch {
                // The refreshed persisted state below determines whether the card stays open.
            }

            guard let refreshedApprovals = try? await runtime.pendingToolApprovals(
                in: projection.conversationID
            ) else { return }
            onPendingToolApprovalsChanged(refreshedApprovals)

            if let refreshed = refreshedApprovals.first(where: {
                $0.toolCallID == request.toolCallID
            }) {
                selectedApproval = refreshed
            } else if selectedApproval?.toolCallID == request.toolCallID {
                selectedApproval = nil
            }
        }
    }
}

/// One Turn, in the order the projection produced.
///
/// Nothing is reordered, grouped or annotated here: the projection already decided what a
/// turn contains and in which order, and a view that second-guessed it would be a second
/// place where the reading order is defined.
private struct ConversationTurnView: View {
    let turn: ConversationTurn
    let onQuoteReference: (QuoteReference) -> Void
    let onQuoteDragPhaseChanged: (ComposerQuoteDragPhase) -> Void
    let onSelectionHandleDragChanged: (Bool) -> Void

    @ScaledMetric(relativeTo: .body) private var withinTurn = Metrics.withinTurn

    var body: some View {
        VStack(alignment: .leading, spacing: withinTurn) {
            // Items are not `Identifiable` — their identity is their position in this turn,
            // which is what the projection's order means.
            ForEach(Array(turn.items.enumerated()), id: \.offset) { entry in
                TimelineItemView(
                    item: entry.element,
                    textSource: turn.textSourcesByItemIndex[entry.offset],
                    onQuoteReference: onQuoteReference,
                    onQuoteDragPhaseChanged: onQuoteDragPhaseChanged,
                    onSelectionHandleDragChanged: onSelectionHandleDragChanged
                )
            }
        }
    }
}

/// One line of a Turn.
///
/// Every role below resolves through the Typography token layer, and this view names no
/// face, no point size and no weight of its own. `dynamicTypeSize` is read here so a change
/// to the reader's text size re-derives each of those sizes rather than leaving the layout
/// on a stale one.
private struct TimelineItemView: View {
    let item: TimelineItem
    let textSource: TimelineTextSource?
    let onQuoteReference: (QuoteReference) -> Void
    let onQuoteDragPhaseChanged: (ComposerQuoteDragPhase) -> Void
    let onSelectionHandleDragChanged: (Bool) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var inlineSpacing = Metrics.inlineSpacing
    @ScaledMetric(relativeTo: .body) private var secondaryInset = Metrics.secondaryInset
    @ScaledMetric(relativeTo: .body) private var readingInset = Metrics.capsulePadding

    @ViewBuilder
    var body: some View {
        switch item {
        case .userText(let text):
            PromptCapsuleView(
                text: text,
                source: textSource,
                onQuoteReference: onQuoteReference,
                onQuoteDragPhaseChanged: onQuoteDragPhaseChanged,
                onSelectionHandleDragChanged: onSelectionHandleDragChanged
            )

        case .assistantText(let text):
            // No bubble: the assistant's text is the reading body itself.
            selectableText(
                text,
                role: .conversationBody,
                source: textSource,
                maximumNumberOfLines: 0
            )
            .padding(.horizontal, readingInset)

        case .reasoning(let text):
            Text(text)
                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(.secondary)
                .lineLimit(Metrics.collapsedSecondaryLines)
                .padding(.leading, secondaryInset)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .toolCall(let call):
            HStack(alignment: .firstTextBaseline, spacing: inlineSpacing) {
                Text(call.action)
                    .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                Text(call.state.rawValue)
                    .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, secondaryInset)

        case .toolResult(let result):
            Text(result.payload)
                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(.secondary)
                .lineLimit(Metrics.collapsedSecondaryLines)
                .padding(.leading, secondaryInset)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .runNotice(let notice):
            HStack(alignment: .firstTextBaseline, spacing: inlineSpacing) {
                if let explanation = notice.explanation {
                    Text(explanation)
                        .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                } else {
                    Text(notice.state.rawValue)
                        .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .quoteReferences(let references):
            QuoteShelfView(entries: references.map(QuoteShelfEntry.init))
        }
    }

    @ViewBuilder
    private func selectableText(
        _ text: String,
        role: TypographyRole,
        source: TimelineTextSource?,
        maximumNumberOfLines: Int
    ) -> some View {
        if let source {
            let quoteSource = source.quoteSource(text: text)
            QuoteSelectableText(
                text: text,
                source: quoteSource,
                typographyRole: role,
                dynamicTypeSize: dynamicTypeSize,
                maximumNumberOfLines: maximumNumberOfLines,
                onDragPhaseChanged: onQuoteDragPhaseChanged,
                onSelectionHandleDragChanged: onSelectionHandleDragChanged
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAction(named: Text("引用整段")) {
                quoteEntireText(quoteSource)
            }
        } else {
            Text(text)
                .font(Typography.font(for: role, dynamicTypeSize: dynamicTypeSize))
                .tracking(Typography.readingSpacing(for: role).tracking)
                .lineSpacing(Typography.readingSpacing(for: role).lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quoteEntireText(_ source: QuoteSourceText) {
        let range = NSRange(location: 0, length: (source.text as NSString).length)
        guard let drag = InternalQuoteDrag.capture(source: source, selectedUTF16Range: range) else {
            return
        }
        onQuoteReference(drag.reference)
    }
}

/// The user's own message, kept in the same left column as the assistant's text.
///
/// Two lines collapsed, tap to expand the whole message. The expansion is presentation
/// state only — it never touches the stored message, and collapsing it again is not a
/// message edit (Blueprint 3.1).
private struct PromptCapsuleView: View {
    let text: String
    let source: TimelineTextSource?
    let onQuoteReference: (QuoteReference) -> Void
    let onQuoteDragPhaseChanged: (ComposerQuoteDragPhase) -> Void
    let onSelectionHandleDragChanged: (Bool) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false
    @ScaledMetric(relativeTo: .body) private var capsulePadding = Metrics.capsulePadding

    var body: some View {
        promptText
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(capsulePadding)
            // The Blueprint asks for a semantic `userPromptSurface` token with its own light
            // and dark values. That token layer is not this item's job, so the system's
            // semantic background stands in rather than a palette invented here.
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: Metrics.capsuleCornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.capsuleCornerRadius, style: .continuous))
            .accessibilityAction(named: Text("引用整段")) {
                quoteEntireText()
            }
    }

    @ViewBuilder
    private var promptText: some View {
        if let source {
            QuoteSelectableText(
                text: text,
                source: source.quoteSource(text: text),
                typographyRole: .conversationPrompt,
                dynamicTypeSize: dynamicTypeSize,
                maximumNumberOfLines: isExpanded ? 0 : Metrics.collapsedPromptLines,
                onSingleTap: { isExpanded.toggle() },
                onDragPhaseChanged: onQuoteDragPhaseChanged,
                onSelectionHandleDragChanged: onSelectionHandleDragChanged
            )
        } else {
            Text(text)
                .font(Typography.font(for: .conversationPrompt, dynamicTypeSize: dynamicTypeSize))
                .tracking(Typography.readingSpacing(for: .conversationPrompt).tracking)
                .lineSpacing(Typography.readingSpacing(for: .conversationPrompt).lineSpacing)
                .lineLimit(isExpanded ? nil : Metrics.collapsedPromptLines)
                .onTapGesture { isExpanded.toggle() }
        }
    }

    private func quoteEntireText() {
        guard let source,
              let drag = InternalQuoteDrag.capture(
                source: source.quoteSource(text: text),
                selectedUTF16Range: NSRange(location: 0, length: (text as NSString).length)
              )
        else { return }
        onQuoteReference(drag.reference)
    }
}

/// Spacing and shape for the reading layout.
///
/// Every number here is a **starting point to calibrate on device, not a measured result** —
/// the Blueprint leaves the reading rhythm to device calibration. The ones used as spacing
/// are applied through `@ScaledMetric` at the call site, so the separation grows with the
/// reader's text size instead of the type crowding together at accessibility sizes.
private enum Metrics {
    /// Between two Turns. Deliberately much larger than the spacing inside one: this gap is
    /// what marks a turn boundary, standing in for a divider.
    static let betweenTurns: CGFloat = 28
    /// Between the items of one Turn — tight enough that they read as one utterance.
    static let withinTurn: CGFloat = 10
    /// Leading inset for secondary content (reasoning, tool activity), which sits under the
    /// text it belongs to rather than beside it.
    static let secondaryInset: CGFloat = 2
    /// Between two things on one line.
    static let inlineSpacing: CGFloat = 8
    /// Screen-edge inset for the whole reading column.
    static let contentInset: CGFloat = 20
    /// Padding inside the user prompt capsule.
    static let capsulePadding: CGFloat = 12
    /// Corner radius of the user prompt capsule. Continuous, so it reads as one soft surface
    /// rather than as four arcs. Not scaled with text: it is a shape, not a distance.
    static let capsuleCornerRadius: CGFloat = 16
    /// A prompt reads as two lines while collapsed; a tap expands it to the whole message.
    static let collapsedPromptLines = 2
    /// Secondary activity collapses to a single line — a pointer to what happened rather than
    /// a summary of it.
    static let collapsedSecondaryLines = 1
}
