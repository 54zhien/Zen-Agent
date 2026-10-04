import SwiftUI
import UIKit

private struct SurfaceLiftControllerKey: EnvironmentKey {
    static let defaultValue: SurfaceLiftController? = nil
}

private struct SurfaceBrowseControllerKey: EnvironmentKey {
    static let defaultValue: AppSpaceBrowseController? = nil
}

private struct WorkspaceLayoutRevisionKey: EnvironmentKey {
    static let defaultValue: UInt64 = 0
}

private struct WorkspaceInputSuppressedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WorkspaceNavigationKey: EnvironmentKey {
    static let defaultValue: WorkspaceNavigationState? = nil
}

extension EnvironmentValues {
    var workspaceNavigation: WorkspaceNavigationState? {
        get { self[WorkspaceNavigationKey.self] }
        set { self[WorkspaceNavigationKey.self] = newValue }
    }
    var workspaceInputSuppressed: Bool {
        get { self[WorkspaceInputSuppressedKey.self] }
        set { self[WorkspaceInputSuppressedKey.self] = newValue }
    }
    var workspaceLayoutRevision: UInt64 {
        get { self[WorkspaceLayoutRevisionKey.self] }
        set { self[WorkspaceLayoutRevisionKey.self] = newValue }
    }
    var surfaceLiftController: SurfaceLiftController? {
        get { self[SurfaceLiftControllerKey.self] }
        set { self[SurfaceLiftControllerKey.self] = newValue }
    }
    var surfaceBrowseController: AppSpaceBrowseController? {
        get { self[SurfaceBrowseControllerKey.self] }
        set { self[SurfaceBrowseControllerKey.self] = newValue }
    }
}

@MainActor
struct WorkspaceSurfaceView<Content: View>: View {
    let content: Content
    private let contentForSlot: ((WorkspaceSurfaceSlot) -> Content)?
    private let model: AppShellModel?
    @State private var lift: SurfaceLiftController
    @State private var secondaryLift = SurfaceLiftController()
    @State private var browse = AppSpaceBrowseController()
    @State private var requestedMenuID: String?
    @State private var resize = SplitResizeController()
    @State private var layoutState = WorkspaceLayoutState()
    private var layoutContext: WorkspaceLayoutContext? { layoutState.context }
    private var navigationInsets: EdgeInsets {
        let insets = layoutContext?.windowSafeAreaInsets ?? .zero
        return EdgeInsets(top: insets.top,
            leading: layoutDirection == .rightToLeft ? insets.right : insets.left,
            bottom: insets.bottom,
            trailing: layoutDirection == .rightToLeft ? insets.left : insets.right)
    }
    @State private var returnPresentation = WorkspaceReturnPresentation()
    @State private var navigation = WorkspaceNavigationState()
    @Environment(\.layoutDirection) private var layoutDirection
    @ScaledMetric(relativeTo: .body) private var minimumWidth = 220.0
    @ScaledMetric(relativeTo: .body) private var minimumHeight = 300.0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(model: AppShellModel? = nil, liftController: SurfaceLiftController = SurfaceLiftController(),
         @ViewBuilder content: () -> Content) {
        _lift = State(initialValue: liftController)
        self.model = model
        self.content = content()
        contentForSlot = nil
    }

    init(model: AppShellModel, @ViewBuilder contentForSlot: @escaping (WorkspaceSurfaceSlot) -> Content) {
        _lift = State(initialValue: SurfaceLiftController())
        self.model = model
        self.contentForSlot = contentForSlot
        content = contentForSlot(.primary)
    }

    private var deleteAction: AppSpaceCardDeletionInteraction.Commit? {
        guard let model else { return nil }
        return { id, stillSelected in
            await model.deleteAppSpaceConversation(id: id, stillSelected: {
                model.previewContent.isPresented && activeLift.state.phase == .card && stillSelected()
            })
        }
    }

    private var isDeletionPending: (@MainActor (String) -> Bool)? {
        guard let model else { return nil }
        return { id in model.cardDeletion?.pendingCards.contains { $0.conversationID == id } == true }
    }

    var body: some View {
        WorkspaceNavigationView(state: navigation, model: model, captureFocus: captureOverlayFocus,
                                canConfigureNew: canConfigureNew,
                                spatiallyAvailable: sidebarSpatiallyAvailable,
                                windowInsets: navigationInsets,
                                context: sidebarContext) {
        ZStack(alignment: .topLeading) {
            Color.clear
            if model?.previewContent.isPresented == true, let layout = browse.layout() {
                ForEach(layout.cards.filter { $0.item != browse.state.selected }
                    .map { browse.deletionProjection($0, in: layout) }, id: \.item) { card in
                    projectedCard(card)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .opacity(card.opacity)
                        .position(x: card.frame.midX, y: card.frame.midY)
                        .zIndex(4 - card.depth)
                }
            }
            GeometryReader { geometry in
                let fullFrame = CGRect(origin: .zero, size: geometry.size)
                ZStack(alignment: .topLeading) {
#if DEBUG
                    if (ProcessInfo.processInfo.environment["ZEN_SURFACE_LIFT_UI_TEST"] == "1"
                        || ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1"),
                       let layout = splitGeometry(in: geometry) {
                        SplitViewportProbe(value: "size=\(geometry.size);safeArea=\(geometry.safeAreaInsets);viewport=\(layout.viewport);top=\(layout.top);bottom=\(layout.bottom)")
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                    }
#endif
                    ForEach(WorkspaceSurfaceSlot.allCases, id: \.self) { slot in
                        let driver = controller(for: slot)
                        let frame = driver.retainsAppSpaceViewport ? fullFrame
                            : splitFrame(in: geometry, slot: logicalSlot(for: slot)) ?? fullFrame
                        let visible = surfaceIsVisible(slot)
                        let suppressed = returnPresentation.suppressesTarget(slot)
                        ConversationSurfaceHost(liftController: driver,
                            browseController: model != nil && slot == (model?.previewSurfaceSlot ?? model?.sourceSurfaceSlot) ? browse : nil,
                            deleteAction: deleteAction, isDeletionPending: isDeletionPending,
                            isWorkspaceVisible: visible, isInputSuppressed: suppressed,
                            isReturnProxyHidden: returnPresentation.hidesOrigin(slot),
                            sidebarOffset: slot == model?.sourceSurfaceSlot
                                ? CGFloat(navigation.progress) * min(geometry.size.width, 60 + navigationInsets.leading)
                                    * (layoutDirection == .rightToLeft ? -1 : 1) : 0,
                            sidebarSettlement: slot == model?.sourceSurfaceSlot ? navigation.settlementID : nil,
                            onSidebarSettled: navigation.completeSettlement,
                            onNativeLayout: { [weak model] receipt in
                                guard let model else { return }
                                returnPresentation.nativeLayout(receipt, slot: slot, currentContext: layoutContext,
                                    model: model, visibilityRevision: driver.workspaceVisibilityRevision)
                            }) {
                            WorkspaceHostedContent(model: model, slot: slot, browse: browse,
                                returnPresentation: returnPresentation, navigation: navigation,
                                content: content, contentForSlot: contentForSlot)
                                .environment(\.surfaceLiftController, driver)
                                .environment(\.surfaceBrowseController, model == nil ? nil : browse)
                        }
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        // Native visibility detaches inactive content and clears
                        // its hidden gate before restoring the retained responder.
                        // A second SwiftUI opacity gate updates afterward and can
                        // leave that responder waiting with no new native callback.
                        .allowsHitTesting(visible && !suppressed)
                        .accessibilityHidden(!visible || suppressed)
                        .zIndex(activeSurfaceSlot == slot ? 10 : 0)
                    }

                    if let model, let split = model.splitWorkspace,
                       let emptyFrame = splitFrame(in: geometry, slot: split.emptySlot) {
                        if model.splitPane == nil, activeSurfaceSlot == nil {
                            SplitEmptyPanePicker(summaries: model.recentConversations,
                                occupiedID: split.sourceConversationID,
                                errorMessage: model.splitOpenError ?? model.recentLoadError,
                                hasMore: model.recentHasMore,
                                onLoadMore: model.loadMoreRecentConversations,
                                onRetry: model.retryRecentConversations,
                                onOpen: { id in Task { _ = await model.openInSplit(id: id) } },
                                onNew: { _ = model.createNewInSplit() })
                                .frame(width: emptyFrame.width, height: emptyFrame.height)
                                .position(x: emptyFrame.midX, y: emptyFrame.midY)
                        }
                        if activeSurfaceSlot == nil, let layout = splitGeometry(in: geometry) {
                            divider(model: model, split: split, layout: layout)
                                .position(x: layout.divider.midX, y: layout.divider.midY)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(WorkspaceLayoutObserver { context in
                    guard layoutContext != context else { return }
                    if let previous = layoutContext, let model,
                       context.requiresResizeCancellation(from: previous) {
                        resize.cancelForPresentationChange(model: model)
                    }
                    if let previous = layoutContext,
                       previous.windowID != context.windowID || previous.windowSize != context.windowSize {
                        navigation.reset()
                    }
                    // The first observer report establishes the coordinate
                    // baseline; it is not an interruption of an existing one.
                    if layoutContext != nil, returnPresentation.phase != nil {
                        controller(for: returnPresentation.plan?.originSlot ?? .primary).invalidate()
                    }
                    layoutState.context = context
                })
            }
            .zIndex(4 - (browse.layout()?.cards.first { $0.item == browse.state.selected }?.depth ?? 0))
            if activeLift.splitTargetingVisible, let top = activeLift.splitTopFrame,
               let bottom = activeLift.splitBottomFrame, let guide = activeLift.splitGuideFrame {
                splitTargetOverlay(top: top, bottom: bottom, guide: guide)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(50)
            }
            if let model, model.previewContent.isPresented, !browse.isNewEntry, browse.canEditCurrentMetadata,
               let summary = browse.currentSummary,
               let frame = browse.layout()?.cards.first(where: { $0.item == browse.state.selected })?.frame {
                AppSpaceCardActionsView(model: model, browse: browse, lift: activeLift,
                    summary: summary, requestedID: $requestedMenuID)
                    .position(x: frame.maxX - 24, y: frame.minY + 24)
                    .zIndex(100)
            }
            if let model, let deletion = model.cardDeletion,
               activeSurfaceSlot != nil || model.pane == nil,
               !deletion.pendingCards.isEmpty || deletion.errorMessage != nil {
                WorkspaceDeletionNotice(model: model, deletion: deletion, browse: browse)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 36)
                    .zIndex(200)
            }
#if DEBUG
            if ProcessInfo.processInfo.environment["ZEN_RETURN_RECEIPT_PAUSE_UI_TEST"] == "1",
               returnPresentation.receiptReady, returnPresentation.phase == .awaitingTarget {
                Button("Continue Return") { returnPresentation.resume() }
                    .accessibilityIdentifier("workspace-return-resume")
                    .accessibilityValue("ready")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 20)
                    .zIndex(250)
            }
            if ProcessInfo.processInfo.environment["ZEN_SURFACE_LIFT_UI_TEST"] == "1"
                || ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1" {
                SurfaceLiftStateProbe(phase: lift.state.phase,
                                      identifier: "surface-lift-state-probe")
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                SurfaceLiftStateProbe(phase: secondaryLift.state.phase,
                                      identifier: "split-secondary-lift-state-probe")
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                SurfaceInteractionProbe(identifier: "surface-native-interaction-probe", driver: lift)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                SurfaceInteractionProbe(identifier: "split-secondary-native-interaction-probe", driver: secondaryLift)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                SplitDropIntentProbe(slot: lift.lastSplitDropIntent?.slot)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
#endif
        }
        }
        // Split shares the keyboard-safe viewport; each retained Composer's
        // native keyboard guide still owns its controls inside that Pane.
        .ignoresSafeArea(.container)
        .onAppear {
            if let model {
                let browseController = browse
                browse.configure(reader: { [weak model] id in
                    guard let model else { throw PersistenceError.conversationNotFound(id) }
                    return try model.browseWindow(id: id)
                })
                browse.configureNewEntry(reader: { [weak model] in
                    guard let model else { throw AppTargetFailure.persistenceUnavailable }
                    return try model.newConversationBrowseWindow()
                })
                let menuRequest = $requestedMenuID
                browse.onOpenActions = { [weak browseController, weak model] in
                    guard let browseController, let model, model.previewContent.isPresented,
                          !model.previewContent.isPreparing, !browseController.isNewEntry,
                          browseController.canEditCurrentMetadata,
                          let id = browseController.currentSummary?.id else { return false }
                    menuRequest.wrappedValue = id
                    return true
                }
                for slot in WorkspaceSurfaceSlot.allCases {
                    let driver = controller(for: slot)
                    driver.workspaceNavigation = navigation
                    configurePreview(driver, model: model, slot: slot)
#if DEBUG
                    driver.workspacePaneDiagnostic = { [weak model] in
                        guard let model else { return "released owner" }
                        let pane = slot == model.sourceSurfaceSlot ? model.pane : model.splitPane
                        return "modelRevision=\(model.workspaceLayoutRevision);\(pane?.scrollBridge.dividerDiagnostic ?? "no pane")"
                    }
#endif
                    driver.configureSplit(onDrop: { [weak model] intent in
                        model?.acceptsSplitDrop(intent) ?? false
                    }, onConverged: { [weak model, weak driver] intent in
                        if model?.commitSplitDrop(intent) != true { _ = driver?.returnToFull() }
                    })
                }
                lift.setSplitWorkspacePresented(model.splitWorkspace != nil)
                secondaryLift.setSplitWorkspacePresented(model.splitWorkspace != nil)
                if model.previewContent.isPresented {
                    browse.present(originID: model.previewContent.originID ?? model.conversationID,
                                   fallback: model.previewContent.summaries)
                    model.previewContent.releaseSummaryWindow()
                }
            }
            updateMinimumSize()
        }
        .task(id: model?.previewContent.isPresented) {
            guard let model, model.previewContent.isPresented else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard model.previewContent.isPresented else { return }
                if !model.previewContent.isPreparing { browse.refresh() }
            }
        }
        .onChange(of: cardLabel) { _, _ in
            lift.refreshCardAccessibility()
            secondaryLift.refreshCardAccessibility()
        }
        .onChange(of: model?.previewContent.isPresented) { _, presented in
            if presented != true {
                browse.finish()
                if !returnPresentation.holdsPreview { returnPresentation.cancel() }
            }
        }
        .onChange(of: model?.splitWorkspace) { _, split in
            if let model { _ = returnPresentation.validateOwnership(model) }
            if resize.isActive, let model, !resize.matches(model),
               split != nil || !resize.isClosing { resize.invalidate() }
            lift.setSplitWorkspacePresented(split != nil)
            secondaryLift.setSplitWorkspacePresented(split != nil)
        }
        .onChange(of: model?.pane.map(ObjectIdentifier.init)) { _, _ in
            if let model { _ = returnPresentation.validateOwnership(model) }
        }
        .onChange(of: model?.splitPane.map(ObjectIdentifier.init)) { _, _ in
            if let model { _ = returnPresentation.validateOwnership(model) }
        }
        .onChange(of: resize.isActive) { _, active in
            lift.workspaceResizeActive = active
            secondaryLift.workspaceResizeActive = active
        }
        .onChange(of: sidebarSpatiallyAvailable) { _, available in
            if !available { navigation.reset() }
        }
        .onChange(of: model?.pane.map(ObjectIdentifier.init)) { _, _ in navigation.reset() }
        .onDisappear { navigation.reset(); resize.invalidate(); returnPresentation.abort() }
        .onChange(of: dynamicTypeSize) { _, _ in updateMinimumSize() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                navigation.reset()
                if resize.isActive, !resize.isClosing, let model { resize.cancelForPresentationChange(model: model) }
                browse.cancel(); lift.invalidate(); secondaryLift.invalidate()
            }
        }
    }

    private var sidebarSpatiallyAvailable: Bool {
        guard let model else { return false }
        // First accepted Send creates the durable Conversation without replacing
        // its Pane. Observe publication so the accessibility action can appear.
        _ = model.pane?.hasPublishedTurn
        return scenePhase == .active && model.pane != nil && model.isCurrentConversationVisible
            && model.splitWorkspace == nil && !model.previewContent.isPresented
            && activeSurfaceSlot == nil && !resize.isActive && returnPresentation.phase == nil
    }

    private func sidebarContext() -> WorkspaceSidebarNativeContext? {
        guard sidebarSpatiallyAvailable, let model, let pane = model.pane,
              let native = controller(for: model.sourceSurfaceSlot).sidebarNativeContext?() else { return nil }
        return WorkspaceSidebarNativeContext(hostID: native.hostID, paneID: ObjectIdentifier(pane),
            window: native.window, allowsOpening: native.allowsOpening
                && !pane.composer.isComposing && !pane.composer.isSelectionHandleDragging
                && pane.composer.quoteDragPhase == .idle,
            allowsClosing: native.allowsClosing, surfaceView: native.surfaceView)
    }

    private func canConfigureNew(_ id: String) -> Bool {
        guard scenePhase == .active, let model, model.currentSettingsNewID == id, let pane = model.pane,
              activeSurfaceSlot == nil, !resize.isActive, returnPresentation.phase == nil,
              let native = controller(for: model.sourceSurfaceSlot).sidebarNativeContext?() else { return false }
        return native.allowsOpening && !pane.composer.isComposing && !pane.composer.isSelectionHandleDragging
            && pane.composer.quoteDragPhase == .idle
    }

    private func captureOverlayFocus() -> ComposerOverlayFocus? {
        guard let model, let pane = model.pane else { return nil }
        let driver = controller(for: model.sourceSurfaceSlot)
        let host = driver.nativeHostIdentity
        return driver.captureOverlayFocus? { [weak model, weak pane, weak driver] in
            guard let model, let pane, let driver else { return false }
            return model.pane === pane && driver.nativeHostIdentity == host
                && model.splitWorkspace == nil && !model.previewContent.isPresented
        }
    }

    private var activeLift: SurfaceLiftController {
        controller(for: activeSurfaceSlot ?? model?.sourceSurfaceSlot ?? .primary)
    }

    private func controller(for slot: WorkspaceSurfaceSlot) -> SurfaceLiftController {
        slot == .primary ? lift : secondaryLift
    }

    private var activeSurfaceSlot: WorkspaceSurfaceSlot? {
        if returnPresentation.holdsPreview, returnPresentation.phase != .restoringOrigin {
            return returnPresentation.plan?.originSlot
        }
        if let slot = model?.previewSurfaceSlot { return slot }
        return WorkspaceSurfaceSlot.allCases.first { controller(for: $0).state.phase != .full }
    }

    private func logicalSlot(for slot: WorkspaceSurfaceSlot) -> SplitDropSlot? {
        guard let model, let split = model.splitWorkspace else { return nil }
        return slot == model.sourceSurfaceSlot ? split.sourceSlot : split.emptySlot
    }

    private func surfaceIsVisible(_ slot: WorkspaceSurfaceSlot) -> Bool {
        if navigation.overlay != nil { return false }
        if returnPresentation.hidesOrigin(slot) { return false }
        if returnPresentation.measuresTarget(slot) { return true }
        if let activeSurfaceSlot { return activeSurfaceSlot == slot }
        guard let model else { return slot == .primary }
        if case .landscapeSingle(let logical) = devicePresentation {
            return logicalSlot(for: slot) == logical && (slot == model.sourceSurfaceSlot || model.splitPane != nil)
        }
        return slot == model.sourceSurfaceSlot || model.splitPane != nil
    }

    private var devicePresentation: WorkspaceDevicePresentation {
        WorkspaceDevicePresentation.resolve(isPad: layoutContext?.isPad ?? false,
            size: layoutContext?.windowSize ?? .zero, split: model?.splitWorkspace)
    }

    private func configurePreview(_ controller: SurfaceLiftController,
                                  model: AppShellModel, slot: WorkspaceSurfaceSlot) {
        let browseController = browse
        let presentation = returnPresentation
        let layout = layoutState
        let primaryDriver = lift
        let secondaryDriver = secondaryLift
        controller.configurePreview(
            enter: { [weak model, weak browseController] in
                guard let model, let browseController else { return false }
                if let split = model.splitWorkspace {
                    model.selectSplitSlot(slot == model.sourceSurfaceSlot ? split.sourceSlot : split.emptySlot)
                } else if slot != model.sourceSurfaceSlot { return false }
                guard model.enterPreview() else { return false }
                browseController.present(originID: model.previewContent.originID ?? model.conversationID,
                                         fallback: model.previewContent.summaries)
                model.previewContent.releaseSummaryWindow()
                return true
            },
            prepare: { [weak model, weak browseController, weak controller, weak presentation,
                        weak layout, weak primaryDriver, weak secondaryDriver] in
                guard let model, let browseController, let controller, let presentation, let layout else { return false }
                browseController.cancel()
                if browseController.isNewEntry {
                    do {
                        let id = try model.createConversationFromAppSpace()
                        guard browseController.selectCreatedConversation(id: id) else { return false }
                        model.acknowledgeAppSpaceCreation(id: id)
                    } catch { return false }
                }
                let selectedID = browseController.selectedConversationID
                let split = model.previewRestoresSplit ? model.splitWorkspace : nil
                guard split == nil || layout.context != nil else { return false }
                let policy = WorkspaceDevicePresentation.resolve(isPad: layout.context?.isPad ?? false,
                    size: layout.context?.windowSize ?? .zero, split: split)
                let plan = WorkspaceReturnPlan.resolve(split: split, sourceSurfaceSlot: model.sourceSurfaceSlot,
                    originSlot: slot, selectedID: selectedID, presentation: policy)
                let targetDriver = plan.targetSurfaceSlot == .primary ? primaryDriver : secondaryDriver
                let targetPane = plan.targetSurfaceSlot == model.sourceSurfaceSlot ? model.pane : model.splitPane
                let descriptor = WorkspaceHeldPreview(summary: browseController.currentSummary,
                    status: model.previewContent.status(for: selectedID, summary: browseController.currentSummary,
                        summaryError: browseController.errorMessage), isNewEntry: browseController.isNewEntry,
                    label: Self.cardLabel(model: model, browse: browseController))
                presentation.prepare(plan: plan, preview: descriptor, pane: targetPane,
                    targetHostID: targetDriver?.nativeHostIdentity, context: layout.context,
                    hideOrigin: { [weak controller] in controller?.hideNativeReturnProxy() },
                    clearLabel: { [weak controller] in controller?.setHeldReturnCardLabel(nil) },
                    interruptOrigin: { [weak controller] in controller?.invalidate() })
                if plan.holdsPreviewThroughReturn { controller.setHeldReturnCardLabel(descriptor.label) }
                let ready = await model.preparePreviewReturn(to: selectedID)
                if !ready { presentation.cancel() }
                return ready
            },
            commit: { [weak model, weak controller] in
                model?.commitPreviewReturn(openingSplitAt: controller?.requestedSplitReturnSlot) ?? false
            },
            cancel: { [weak model] in
                guard let model, model.previewContent.isPresented else { return }
                guard model.previewSurfaceSlot == slot else { return }
                model.cancelPreviewReturn()
            },
            isPresented: { [weak model] in
                guard let model, model.previewContent.isPresented else { return false }
                return model.previewSurfaceSlot == slot
            },
            label: { [weak model, weak browseController] in
                guard let model, let browseController else { return "当前会话" }
                return Self.cardLabel(model: model, browse: browseController)
            })
        controller.configureReturnDestination { [weak model, weak controller, weak layout, weak presentation] size, insets in
            if let context = layout?.context {
                if let slot = controller?.requestedSplitReturnSlot {
                    return SplitWorkspaceGeometry(viewport: context.frame, ratio: 0.5)?.frame(for: slot)
                }
                if let plan = presentation?.plan {
                    return plan.destination(in: context.frame, safeArea: .zero)
                }
                return context.frame
            }
            let destination = controller?.requestedSplitReturnSlot
                ?? (model?.previewRestoresSplit == true ? model?.splitPreviewOriginSlot : nil)
            guard let destination else { return CGRect(origin: .zero, size: size) }
            return SplitWorkspaceGeometry(size: size, safeArea: insets,
                ratio: model?.splitWorkspace?.activeRatio ?? 0.5,
                axis: model?.splitWorkspace?.axis ?? .topBottom)?.frame(for: destination)
        }
        controller.configureExternalReturn(begin: { [weak model, weak presentation] animation in
            guard let model, let presentation, presentation.plan?.originSlot == slot else { return nil }
            return presentation.begin(commit: { model.commitPreviewReturn() }, animate: animation)
        }, cancel: { [weak presentation] in
            if presentation?.plan?.originSlot == slot { presentation?.cancel() }
        })
    }

    private var cardLabel: String {
        guard let model else { return "当前会话" }
        return Self.cardLabel(model: model, browse: browse)
    }

    private func splitFrame(in geometry: GeometryProxy, slot: SplitDropSlot?) -> CGRect? {
        guard let slot else { return nil }
        return splitGeometry(in: geometry)?.frame(for: slot)
    }

    private func splitGeometry(in geometry: GeometryProxy) -> SplitWorkspaceGeometry? {
        guard let split = model?.splitWorkspace, case .split(let axis) = devicePresentation else { return nil }
        // Workspace ignores container regions; its proposed size already avoids
        // the keyboard. GeometryProxy can still report that keyboard's Insets,
        // so applying them again would shrink both Panes a second time.
        return SplitWorkspaceGeometry(viewport: CGRect(origin: .zero, size: geometry.size),
            ratio: split.activeRatio, axis: axis)
    }

    private func divider(model: AppShellModel, split: SplitWorkspaceState,
                         layout: SplitWorkspaceGeometry) -> some View {
        let horizontal = split.axis == .leftRight
        let length = horizontal ? layout.viewport.width : layout.viewport.height
        let minimum = SplitWorkspaceGeometry.minimumRatio(height: length,
            preferredMinimum: horizontal ? minimumWidth : max(180, minimumHeight * 0.65))
        return ZStack {
            Rectangle().fill(Color.white.opacity(0.20))
                .frame(width: horizontal ? 2 : layout.divider.width, height: horizontal ? layout.divider.height : 2)
                .allowsHitTesting(false)
            SplitDividerView(ratio: split.activeRatio, closeIntent: resize.closeIntent,
                canCloseTop: split.sourceSlot == .bottom || split.secondaryConversationID != nil,
                canCloseBottom: split.sourceSlot == .top || split.secondaryConversationID != nil,
                onBegin: { activeSurfaceSlot == nil && resize.begin(model: model, minimumRatio: minimum) },
                onMove: { displacement in
                    resize.update(model: model, displacement: displacement, viewportHeight: length)
                },
                onEnd: { cancelled in resize.finish(model: model, cancelled: cancelled) },
                onClose: { slot in resize.close(model: model, keeping: slot == .top ? .bottom : .top) },
                onAdjust: { increment in resize.adjust(model: model, increment: increment, minimumRatio: minimum) },
                axis: split.axis,
                onAxis: layoutContext?.isPad == true ? { axis in resize.changeAxis(model: model, to: axis) } : nil,
                resizeDiagnostic: resizeDiagnostic)
                .frame(width: horizontal ? 28 : min(64, layout.viewport.width * 0.2),
                       height: horizontal ? min(64, layout.viewport.height * 0.2) : 28)
        }
        .frame(width: layout.divider.width, height: layout.divider.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("split-divider")
    }

    private var resizeDiagnostic: (() -> String)? {
#if DEBUG
        return { resize.diagnostic + ";surface=\(String(describing: activeSurfaceSlot));overlay=\(String(describing: navigation.overlay));preview=\(model?.previewContent.isPresented == true);source=[\(lift.nativeVisibilityDiagnostic?() ?? "unbound")];other=[\(secondaryLift.nativeVisibilityDiagnostic?() ?? "unbound")]" }
#else
        return nil
#endif
    }

    private func splitTargetOverlay(top: CGRect, bottom: CGRect, guide: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            zone(top, selected: activeLift.splitTargetSlot == .top)
            zone(bottom, selected: activeLift.splitTargetSlot == .bottom)
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: min(64, guide.width * 0.2), height: guide.height)
                .position(x: guide.midX, y: guide.midY)
        }
    }

    private func zone(_ frame: CGRect, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(selected ? 0.35 : 0.09), lineWidth: selected ? 1.5 : 1)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.07 : 0.025)))
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private static func cardLabel(model: AppShellModel, browse: AppSpaceBrowseController) -> String {
        if browse.isNewEntry {
            return ["新对话", model.appSpaceActionError(for: nil) ?? browse.errorMessage, "创建新对话"].compactMap { $0 }.joined(separator: "，")
        }
        if browse.currentSummary == nil { return "未发送的会话，轻点返回会话" }
        let status = model.previewContent.status(for: browse.selectedConversationID,
            summary: browse.currentSummary, summaryError: model.appSpaceActionError(for: browse.selectedConversationID) ?? browse.errorMessage)
        return ConversationPreviewController.accessibilityLabel(summary: browse.currentSummary, status: status)
    }

    private func projectedCard(_ card: AppSpaceBrowseGeometry.Card) -> some View {
        let summary: ConversationSummary? = {
            if case .conversation(let id) = card.item { return browse.summaries.first { $0.id == id } }
            return nil
        }()
        let size = browse.viewportSize
        let insets = browse.safeArea
        let pose = AppSpaceBrowseGeometry.pose(for: card, size: size, safeArea: insets)
        // Match the native Current's logical viewport, scaling and crop. Reflowing
        // a predecessor at its thumbnail width would jump its text at commitment.
        return ConversationPreviewView(summary: summary,
            status: summary?.contentUnavailable == true ? .contentUnavailable : .ready,
            isNewEntry: browse.supportsNewEntry && card.item == .newConversation)
            .frame(width: max(1, size.width - insets.left - insets.right),
                height: max(1, size.height - insets.top - insets.bottom))
            .padding(EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
            .scaleEffect(pose?.scale ?? 1)
            .frame(width: card.frame.width, height: card.frame.height)
            .clipShape(RoundedRectangle(cornerRadius: card.cornerRadius, style: .continuous))
    }

    private func updateMinimumSize() {
        browse.updateMinimumCardSize(CGSize(width: minimumWidth, height: minimumHeight))
        lift.minimumCardSize = CGSize(width: minimumWidth, height: minimumHeight)
        secondaryLift.minimumCardSize = CGSize(width: minimumWidth, height: minimumHeight)
        lift.invalidate()
        secondaryLift.invalidate()
    }
}

/// The hosting controller installs this root once. Read the observable owner
/// mapping here so a surviving secondary Surface can become Single in place.
@MainActor
private struct WorkspaceHostedContent<Content: View>: View {
    let model: AppShellModel?
    let slot: WorkspaceSurfaceSlot
    let browse: AppSpaceBrowseController
    let returnPresentation: WorkspaceReturnPresentation
    let navigation: WorkspaceNavigationState
    let content: Content
    let contentForSlot: ((WorkspaceSurfaceSlot) -> Content)?
    @Environment(\.surfaceLiftController) private var lift

    var body: some View {
        Group {
            if let model {
                if let held = returnPresentation.heldPreview(for: slot) {
                    ConversationPreviewView(summary: held.summary, status: held.status, isNewEntry: held.isNewEntry)
                } else if model.previewContent.isPresented, model.previewSurfaceSlot == slot {
                    ConversationPreviewView(
                        summary: browse.isPresented ? browse.currentSummary : model.previewContent.currentSummary,
                        status: model.appSpaceActionError(for: browse.selectedConversationID).map { .failed($0) }
                            ?? (browse.isPresented
                                ? model.previewContent.status(for: browse.selectedConversationID,
                                    summary: browse.currentSummary, summaryError: browse.errorMessage)
                                : model.previewContent.status),
                        isNewEntry: browse.isNewEntry)
                } else if let contentForSlot {
                    contentForSlot(slot)
                } else if slot == model.sourceSurfaceSlot {
                    content
                } else if model.splitWorkspace != nil {
                    SplitSecondaryPaneView(model: model)
                }
            } else if slot == .primary {
                content
            }
        }
        // The nested hosting controller builds its own SwiftUI accessibility
        // tree. Suppress that tree here while preserving the hidden live Pane.
        .accessibilityHidden(navigation.overlay != nil || returnPresentation.suppressesTarget(slot) || (model?.previewContent.isPresented == true
            && model?.previewSurfaceSlot != slot))
        .environment(\.workspaceInputSuppressed, navigation.overlay != nil || returnPresentation.suppressesTarget(slot))
        .environment(\.workspaceNavigation, navigation)
        .environment(\.modelMenuPreferences, model?.modelMenus)
        .preferredColorScheme(model?.appearance.appearance.colorScheme)
        // UIKit installs this root once. Read mutable layout state here so
        // Observation updates the retained subtree instead of freezing a value
        // captured outside the hosting controller at its first installation.
        .environment(\.workspaceLayoutRevision, model?.workspaceLayoutRevision ?? 0)
        .environment(\.conversationBottomNotice, bottomNotice)
    }

    private var bottomNotice: AnyView? {
        guard let model, !model.previewContent.isPresented, lift?.state.phase == .full,
              let deletion = model.cardDeletion,
              !deletion.pendingCards.isEmpty || deletion.errorMessage != nil else { return nil }
        let owner: WorkspaceSurfaceSlot
        if let split = model.splitWorkspace, model.splitPane != nil,
           split.activeSlot == split.emptySlot {
            owner = model.sourceSurfaceSlot == .primary ? .secondary : .primary
        } else {
            owner = model.sourceSurfaceSlot
        }
        guard slot == owner else { return nil }
        return AnyView(WorkspaceDeletionNotice(model: model, deletion: deletion, browse: browse))
    }
}

#if DEBUG
private struct SurfaceInteractionProbe: UIViewRepresentable {
    let identifier: String
    let driver: SurfaceLiftController
    func makeUIView(context: Context) -> SurfaceInteractionProbeView {
        let view = SurfaceInteractionProbeView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
        view.readValue = { [weak driver] in driver?.nativeInteractionDiagnostic?() ?? "unbound" }
        return view
    }
    func updateUIView(_ uiView: SurfaceInteractionProbeView, context: Context) {}
}

private struct SplitViewportProbe: UIViewRepresentable {
    let value: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "split-viewport-probe"
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityValue = value
    }
}

private final class SurfaceInteractionProbeView: UIView {
    var readValue: (() -> String)?
    override var accessibilityValue: String? {
        get { readValue?() ?? super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }
}

private struct SurfaceLiftStateProbe: UIViewRepresentable {
    let phase: SurfaceLiftState.Phase
    let identifier: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityIdentifier = identifier
        uiView.accessibilityValue = String(describing: phase)
    }
}

private struct SplitDropIntentProbe: UIViewRepresentable {
    let slot: SplitDropSlot?
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "split-drop-intent-probe"
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityValue = slot?.rawValue ?? "none"
    }
}

@MainActor
struct SurfaceLiftUITestFixture: View {
    var body: some View {
        WorkspaceSurfaceView { ConversationPaneReadingUITestFixtureView() }
    }
}
#endif
