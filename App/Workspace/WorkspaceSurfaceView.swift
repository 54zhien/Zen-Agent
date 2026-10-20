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
private struct WorkspaceSidebarProgressReader<Content: View>: View {
    let state: WorkspaceNavigationState
    let travel: CGFloat
    let direction: LayoutDirection
    let content: (CGFloat, Bool, CGFloat) -> Content

    var body: some View {
        let progress = CGFloat(state.progress)
        let isDragging = state.isDragging
        let directionSign: CGFloat = direction == .rightToLeft ? -1 : 1
        content(progress, isDragging, progress * travel * directionSign)
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
    @State private var composerDock = WorkspaceComposerDockState()
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
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
                                spatiallyAvailable: sidebarSpatiallyAvailable,
                                windowInsets: navigationInsets,
                                windowCornerRadius: layoutContext?.windowCornerRadius ?? 0,
                                keepsFullConversationViewport: keepsFullConversationViewport,
                                sidebarPageHeight: keepsFullConversationViewport ? layoutContext?.windowSize.height : nil,
                                roundsSidebarPageBottom: keepsFullConversationViewport || !keyboardShortensViewport,
                                context: sidebarContext) {
        ZStack(alignment: .topLeading) {
            AppSpaceStackView(model: model, browse: browse, lift: activeLift,
                requestedMenuID: $requestedMenuID) {
                GeometryReader { proposed in
                    GeometryReader { geometry in
                        WorkspaceSidebarProgressReader(state: navigation,
                            travel: sidebarTravel(in: geometry), direction: layoutDirection) { progress, isDragging, translation in
                            workspaceSurfaces(in: geometry, sidebarProgress: progress,
                                sidebarDragging: isDragging, sidebarTranslation: translation)
                        }
                    }
                    // Physical keyboard avoidance already shortens the outer proposal.
                    // Reserve only its remaining overlap with the replacement sheet,
                    // before splitting into Panes; a lower Pane cannot inset above its top.
                    .padding(.bottom, keepsFullConversationViewport ? 0
                        : composerDock.menuOverlap(in: proposed.frame(in: .global)))
                }
            }
            if activeLift.splitTargetingVisible, let top = activeLift.splitTopFrame,
               let bottom = activeLift.splitBottomFrame, let guide = activeLift.splitGuideFrame {
                splitTargetOverlay(top: top, bottom: bottom, guide: guide)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(50)
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
                        let owners = pane.map {
                            "sessionIdentity=\(ObjectIdentifier($0.session));composerOwnerIdentity=\(ObjectIdentifier($0.composer));readingOwnerIdentity=\(ObjectIdentifier($0.readingPosition))"
                        } ?? "no mounted warm presentation"
                        return "modelRevision=\(model.workspaceLayoutRevision);\(owners);\(pane?.scrollBridge.dividerDiagnostic ?? "no pane")"
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
        .onChange(of: sidebarPresentationAvailable) { _, available in
            if !available { navigation.reset() }
        }
        .onChange(of: model?.pane.map(ObjectIdentifier.init)) { _, _ in navigation.reset() }
        .onDisappear { navigation.reset(); resize.invalidate(); returnPresentation.abort() }
        .onChange(of: dynamicTypeSize) { _, _ in updateMinimumSize() }
        .onChange(of: navigation.isOpen) { _, open in
            guard open, scenePhase == .active else { return }
            // Dismiss only after the opening gesture commits. The keyboard's
            // transition must not invalidate that gesture's admission halfway.
            _ = controller(for: inputSurfaceSlot).sidebarNativeContext?()?.window.endEditing(true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                navigation.suspendInteractions()
                if resize.isActive, !resize.isClosing, let model { resize.cancelForPresentationChange(model: model) }
                browse.cancel(); lift.invalidate(); secondaryLift.invalidate()
            }
        }
    }

    private func workspaceSurfaces(in geometry: GeometryProxy, sidebarProgress: CGFloat,
                                   sidebarDragging: Bool, sidebarTranslation: CGFloat) -> some View {
        // One keyboard-adjusted geometry snapshot drives both native Surfaces,
        // the picker and Divider throughout the outer keyboard transaction.
        let splitLayout = splitGeometry(in: geometry)
        return ZStack(alignment: .topLeading) {
            if model?.splitWorkspace != nil, activeSurfaceSlot == nil {
                Color.black
                if let layout = splitLayout, colorScheme == .dark {
                    Color(white: 0.14)
                        .frame(width: layout.divider.width, height: layout.divider.height)
                        .position(x: layout.divider.midX, y: layout.divider.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if sidebarProgress > 0 || navigation.settlementID != nil {
                sidebarBackdrop(in: geometry, progress: sidebarProgress,
                    isDragging: sidebarDragging)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
#if DEBUG
            if (ProcessInfo.processInfo.environment["ZEN_SURFACE_LIFT_UI_TEST"] == "1"
                || ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1"),
               let layout = splitLayout {
                SplitViewportProbe(value: "size=\(geometry.size);safeArea=\(geometry.safeAreaInsets);viewport=\(layout.viewport);top=\(layout.top);bottom=\(layout.bottom);ratio=\(model?.splitWorkspace?.activeRatio ?? 0)")
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
#endif
            ForEach(WorkspaceSurfaceSlot.allCases, id: \.self) { slot in
                workspaceSurface(slot: slot, geometry: geometry,
                    splitLayout: splitLayout,
                    sidebarProgress: sidebarProgress, sidebarDragging: sidebarDragging,
                    sidebarOffset: sidebarTranslation)
            }

            if let model, let split = model.splitWorkspace, let layout = splitLayout {
                let emptyFrame = layout.frame(for: split.emptySlot)
                if model.splitPane == nil, activeSurfaceSlot == nil {
                    ConversationSurfaceHost(isWorkspaceVisible: navigation.overlay == nil,
                        isInputSuppressed: navigation.overlay != nil,
                        restingCornerRadius: SplitTargetingGeometry.paneCornerRadius,
                        squareBottomCorners: keyboardShortensViewport && abs(emptyFrame.maxY - layout.viewport.maxY) < 1,
                        displayCorners: SplitWorkspaceGeometry.viewportCorners(of: emptyFrame, in: layout.viewport),
                        sidebarOffset: sidebarTranslation, sidebarProgress: sidebarProgress,
                        sidebarDragging: sidebarDragging, sidebarSettlement: navigation.settlementID,
                        sidebarShadowEnabled: false,
                        workspaceViewportSize: emptyFrame.size,
                        workspaceBackgroundColor: .systemBackground,
                        sidebarOutlineExternallyDrawn: usesDockedSidebarOutline(frame: emptyFrame,
                            viewport: layout.viewport, splitLayout: layout)) {
                        WorkspaceSplitPickerContent(model: model)
                    }
                    .frame(width: emptyFrame.width, height: emptyFrame.height)
                    .position(x: emptyFrame.midX, y: emptyFrame.midY)
                }
                if activeSurfaceSlot == nil {
                    divider(model: model, split: split, layout: layout, sidebarProgress: sidebarProgress, sidebarDragging: sidebarDragging)
                        .position(x: layout.divider.midX, y: layout.divider.midY)
                        // Sidebar can open while dismissing the keyboard. Its
                        // timing owns only horizontal transport, not Split layout.
                        .animation(sidebarAnimation(isDragging: sidebarDragging)) { content in
                            content.offset(x: sidebarTranslation)
                        }
                        .zIndex(20)
                }
            }
        }
        .overlay {
            WorkspaceComposerDock(state: composerDock, activeID: inputPane?.conversationID,
                visible: showsWorkspaceComposerDock,
                returnsToPortals: model?.splitWorkspace == nil,
                outlines: dockedSidebarOutlines(in: geometry, progress: sidebarProgress),
                sidebarDragging: sidebarDragging)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: dockCornerRadius,
                    bottomTrailingRadius: dockCornerRadius, style: .continuous))
                .opacity(dockLiftOpacity)
                .animation(sidebarAnimation(isDragging: sidebarDragging)) { content in
                    content.offset(x: sidebarTranslation)
                }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
#if DEBUG
        .overlay {
            if ProcessInfo.processInfo.environment["ZEN_SPLIT_KEYBOARD_STRESS_UI_TEST"] == "1",
               let split = model?.splitWorkspace, splitLayout != nil, activeSurfaceSlot == nil {
                SplitKeyboardStressProbe(driver: controller(for: inputSurfaceSlot),
                    axis: split.axis, ratio: split.activeRatio)
            }
        }
#endif
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
            composerDock.windowSize = context.windowSize
            composerDock.isPad = context.isPad
            layoutState.context = context
        })
    }

    /// The keyboard-safe Workspace ends above the keyboard; its bottom edge is
    /// then no longer the display's rounded edge.
    private var keyboardShortensViewport: Bool {
        layoutContext.map {
            $0.windowSize.height - $0.frame.maxY > $0.windowSafeAreaInsets.bottom + 1
        } ?? false
    }

    private var dockCornerRadius: CGFloat {
        keyboardShortensViewport ? 0 : max(SplitTargetingGeometry.paneCornerRadius,
                                           layoutContext?.windowCornerRadius ?? 0)
    }

    private var showsWorkspaceComposerDock: Bool {
        model?.splitWorkspace != nil && navigation.overlay == nil
            && model?.previewContent.isPresented != true && returnPresentation.phase == nil
            && (activeSurfaceSlot == nil || [.armed, .lifting].contains(activeLift.state.phase)
                || activeLift.state.pendingSettlement?.destination == .card)
    }

    private func sidebarPageAppearance(progress: CGFloat) -> SidebarPageAppearance {
        SidebarPageAppearance(progress: progress, dark: colorScheme == .dark, reduceTransparency: reduceTransparency)
    }

    private func usesDockedSidebarOutline(frame: CGRect, viewport: CGRect,
                                         splitLayout: SplitWorkspaceGeometry?) -> Bool {
        showsWorkspaceComposerDock && activeSurfaceSlot == nil
            && (splitLayout != nil || abs(frame.maxY - viewport.maxY) < 1)
    }

    private func dockedSidebarOutlines(in geometry: GeometryProxy, progress: CGFloat) -> [WorkspaceComposerDockOutline] {
        guard showsWorkspaceComposerDock, activeSurfaceSlot == nil else { return [] }
        let layout = splitGeometry(in: geometry)
        let viewport = layout?.viewport ?? CGRect(origin: .zero, size: geometry.size)
        let appearance = sidebarPageAppearance(progress: progress)
        let strength = appearance.outlineOpacity * appearance.surfaceOpacity
        var outlines: [WorkspaceComposerDockOutline] = WorkspaceSurfaceSlot.allCases.compactMap { slot in
            let driver = controller(for: slot)
            let frame = driver.retainsAppSpaceViewport ? viewport
                : (logicalSlot(for: slot).flatMap { layout?.frame(for: $0) } ?? viewport)
            if surfaceIsVisible(slot), !returnPresentation.suppressesTarget(slot),
               usesDockedSidebarOutline(frame: frame, viewport: viewport, splitLayout: layout) {
                return WorkspaceComposerDockOutline(frame: frame,
                    radii: paneRadii(frame, in: viewport,
                        squareBottom: keyboardShortensViewport && abs(frame.maxY - viewport.maxY) < 1),
                    opacity: strength)
            }
            return nil
        }
        if let layout, let split = model?.splitWorkspace {
            if model?.splitPane == nil {
                let frame = layout.frame(for: split.emptySlot)
                outlines.append(WorkspaceComposerDockOutline(frame: frame,
                    radii: paneRadii(frame, in: viewport,
                        squareBottom: keyboardShortensViewport && abs(frame.maxY - viewport.maxY) < 1),
                    opacity: strength))
            }
        }
        return outlines
    }

    /// The shared Split editor cannot ride inside the lifted Pane mid-gesture:
    /// re-parenting it would cancel the touch that drives Lift. It recedes as
    /// the page rises so the Surface leaves on its own, and stays out while
    /// the page settles into App Space.
    private var dockLiftOpacity: Double {
        guard model?.splitWorkspace != nil, activeSurfaceSlot != nil else { return 1 }
        switch activeLift.state.phase {
        case .armed: return 1
        case .lifting: return max(0, 1 - activeLift.state.progress * 3)
        default: return 0
        }
    }

    private func sidebarAnimation(isDragging: Bool) -> Animation? {
        reduceMotion || isDragging ? nil : .easeOut(duration: 0.22)
    }

    private func sidebarTravel(in geometry: GeometryProxy) -> CGFloat {
        min(geometry.size.width, SidebarRailLayout(windowInsets: navigationInsets,
            cornerRadius: layoutContext?.windowCornerRadius ?? 0).width)
    }

    private func sidebarBackdrop(in geometry: GeometryProxy, progress: CGFloat,
                                 isDragging: Bool) -> some View {
        let splitPageColor = sidebarPageAppearance(progress: 1).surfaceColor(resolving:
            UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        return ZStack(alignment: .topLeading) {
            Color(uiColor: splitGeometry(in: geometry) == nil ? .systemBackground : splitPageColor)
            Color.black.opacity(0.28 * (1 - progress))
                .animation(sidebarAnimation(isDragging: isDragging), value: progress)
            // This is the sole gap backdrop; an extra native gutter would
            // darken the same transition a second time.
        }
        .opacity(SidebarProgressPresentation.opacity(forProgress: Double(progress)))
        .animation(sidebarAnimation(isDragging: isDragging), value: progress)
    }

    private func workspaceSurface(slot: WorkspaceSurfaceSlot, geometry: GeometryProxy,
                                  splitLayout: SplitWorkspaceGeometry?,
                                  sidebarProgress: CGFloat, sidebarDragging: Bool,
                                  sidebarOffset: CGFloat) -> some View {
        let fullFrame = CGRect(origin: .zero, size: geometry.size)
        let driver = controller(for: slot)
        let frame = driver.retainsAppSpaceViewport ? fullFrame
            : (logicalSlot(for: slot).flatMap { splitLayout?.frame(for: $0) } ?? fullFrame)
        let usesWorkspaceViewport = splitLayout != nil && !driver.retainsAppSpaceViewport
        let sharedShadow = activeSurfaceSlot == nil && splitLayout != nil
        let visible = surfaceIsVisible(slot)
        let suppressed = returnPresentation.suppressesTarget(slot)
        let surfaceBrowse: AppSpaceBrowseController? = model != nil && slot == (model?.previewSurfaceSlot ?? model?.sourceSurfaceSlot) ? browse : nil
        let corner: CGFloat = model?.splitWorkspace != nil && !driver.retainsAppSpaceViewport
            ? SplitTargetingGeometry.paneCornerRadius : 0
        // The proposed Workspace already avoids the keyboard. Only square an
        // exterior edge that actually reaches that shortened viewport; inner
        // corners and the black divider retain their normal geometry.
        let squareBottomCorners = model?.splitWorkspace != nil && !driver.retainsAppSpaceViewport
            && keyboardShortensViewport && abs(frame.maxY - fullFrame.maxY) < 1
        let displayCorners = corner > 0 ? SplitWorkspaceGeometry.viewportCorners(of: frame, in: fullFrame) : []
        let settled: ((UUID) -> Void)?
        if slot == inputSurfaceSlot { settled = { navigation.completeSettlement($0) } }
        else { settled = nil }
        let hosted = WorkspaceHostedContent(model: model, slot: slot, browse: browse,
            returnPresentation: returnPresentation, navigation: navigation, composerDock: composerDock,
            content: content, contentForSlot: contentForSlot)
            .environment(\.surfaceLiftController, driver)
            .environment(\.surfaceBrowseController, model == nil ? nil : browse)
        let surface = ConversationSurfaceHost(liftController: driver,
            browseController: surfaceBrowse,
            deleteAction: deleteAction, isDeletionPending: isDeletionPending,
            isWorkspaceVisible: visible, isInputSuppressed: suppressed,
            isReturnProxyHidden: returnPresentation.hidesOrigin(slot),
            restingCornerRadius: corner, squareBottomCorners: squareBottomCorners,
            displayCorners: displayCorners, sidebarOffset: sidebarOffset,
            sidebarProgress: sidebarProgress, sidebarDragging: sidebarDragging,
            sidebarSettlement: navigation.settlementID,
            // Composite the two separate card contours once, matching Single's
            // strength without putting one Pane's shadow under the other.
            sidebarShadowFrame: sharedShadow ? fullFrame.offsetBy(dx: -frame.minX, dy: -frame.minY) : nil,
            sidebarShadowEnabled: !sharedShadow || slot == model?.sourceSurfaceSlot,
            sidebarShadowContours: sharedShadow ? splitLayout.map(splitShadowContours) ?? [] : [],
            workspaceViewportSize: usesWorkspaceViewport ? frame.size : nil,
            sidebarOutlineExternallyDrawn: usesDockedSidebarOutline(frame: frame, viewport: fullFrame, splitLayout: splitLayout),
            onSidebarSettled: settled,
            onNativeLayout: { [weak model, weak resize] receipt in
                guard let model else { return }
                resize?.nativeLayout(receipt, context: layoutContext, slot: slot, model: model)
                returnPresentation.nativeLayout(receipt, slot: slot, currentContext: layoutContext,
                    model: model, visibilityRevision: driver.workspaceVisibilityRevision)
            }, contentOwner: model.flatMap {
                (slot == $0.sourceSurfaceSlot ? $0.pane : $0.splitPane).map(ObjectIdentifier.init)
            }) { hosted }
        return surface
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        // Native visibility detaches inactive content and clears
        // its hidden gate before restoring the retained responder.
        // A second SwiftUI opacity gate updates afterward and can
        // leave that responder waiting with no new native callback.
        .allowsHitTesting(visible && !suppressed)
        .accessibilityHidden(!visible || suppressed)
        .zIndex(activeSurfaceSlot == slot ? 10.0 : 0.0)
    }

    private var sidebarSpatiallyAvailable: Bool {
        scenePhase == .active && sidebarPresentationAvailable
    }

    private var sidebarPresentationAvailable: Bool {
        guard let model else { return false }
        // First accepted Send creates the durable Conversation without replacing
        // its Pane. Observe publication so the accessibility action can appear.
        _ = model.pane?.hasPublishedTurn
        return inputPane != nil
            && !model.previewContent.isPresented
            && activeSurfaceSlot == nil && !resize.isActive && returnPresentation.phase == nil
    }

    private func sidebarContext() -> WorkspaceSidebarNativeContext? {
        guard sidebarSpatiallyAvailable, let pane = inputPane,
              let native = controller(for: inputSurfaceSlot).sidebarNativeContext?() else { return nil }
        let otherSurfaces: [UIView] = WorkspaceSurfaceSlot.allCases.compactMap { slot in
            guard slot != inputSurfaceSlot, surfaceIsVisible(slot) else { return nil }
            return controller(for: slot).sidebarNativeContext?()?.surfaceView
        }
        let dockedInput: [UIView] = controller(for: inputSurfaceSlot).externalComposer.map { [$0] } ?? []
        return WorkspaceSidebarNativeContext(hostID: native.hostID, paneID: ObjectIdentifier(pane),
            window: native.window, allowsOpening: native.allowsOpening
                && !pane.composer.isComposing && !pane.composer.isSelectionHandleDragging
                && pane.composer.quoteDragPhase == .idle,
            allowsClosing: native.allowsClosing, surfaceView: native.surfaceView,
            additionalClosingViews: otherSurfaces + dockedInput)
    }

    private func captureOverlayFocus() -> ComposerOverlayFocus? {
        guard let model, let pane = inputPane else { return nil }
        let capturedSlot = inputSurfaceSlot
        let driver = controller(for: capturedSlot)
        let host = driver.nativeHostIdentity
        return driver.captureOverlayFocus? { [weak model, weak pane, weak driver] in
            guard let model, let pane, let driver else { return false }
            let current = capturedSlot == model.sourceSurfaceSlot ? model.pane : model.splitPane
            return current === pane && driver.nativeHostIdentity == host && !model.previewContent.isPresented
        }
    }

    private var inputSurfaceSlot: WorkspaceSurfaceSlot {
        guard let model else { return .primary }
        guard let split = model.splitWorkspace, split.activeSlot == split.emptySlot else { return model.sourceSurfaceSlot }
        return model.sourceSurfaceSlot.other
    }
    private var inputPane: ConversationPaneController? {
        guard let model else { return nil }
        return inputSurfaceSlot == model.sourceSurfaceSlot ? model.pane : model.splitPane
    }

    private var activeLift: SurfaceLiftController {
        controller(for: activeSurfaceSlot ?? inputSurfaceSlot)
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

    private var keepsFullConversationViewport: Bool {
        if case .split = devicePresentation { return false }
        return true
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

    private func splitGeometry(in geometry: GeometryProxy) -> SplitWorkspaceGeometry? {
        guard let split = model?.splitWorkspace, case .split(let axis) = devicePresentation else { return nil }
        // Workspace ignores container regions; its proposed size already avoids
        // the keyboard. GeometryProxy can still report that keyboard's Insets,
        // so applying them again would shrink both Panes a second time.
        return SplitWorkspaceGeometry(viewport: CGRect(origin: .zero, size: geometry.size),
            ratio: split.activeRatio, axis: axis)
    }

    private func divider(model: AppShellModel, split: SplitWorkspaceState,
                         layout: SplitWorkspaceGeometry, sidebarProgress: CGFloat, sidebarDragging: Bool) -> some View {
        let horizontal = split.axis == .leftRight
        let length = horizontal ? layout.viewport.width : layout.viewport.height
        let minimum = SplitWorkspaceGeometry.minimumRatio(height: length,
            preferredMinimum: horizontal ? minimumWidth : max(180, minimumHeight * 0.65))
        return SplitDividerView(ratio: split.activeRatio, closeIntent: resize.closeIntent,
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
                resizeDiagnostic: resizeDiagnostic, sidebarProgress: sidebarProgress)
                .frame(width: horizontal ? 28 : min(64, layout.viewport.width * 0.2),
                       height: horizontal ? min(64, layout.viewport.height * 0.2) : 28)
        .frame(width: layout.divider.width, height: layout.divider.height)
        .animation(sidebarAnimation(isDragging: sidebarDragging), value: sidebarProgress)
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

    /// The SwiftUI twin of a resting native Pane's corners: display radius on
    /// the display's corners, Pane radius toward the divider.
    private func paneShape(_ frame: CGRect, in viewport: CGRect, squareBottom: Bool = false) -> UnevenRoundedRectangle {
        let radii = paneRadii(frame, in: viewport, squareBottom: squareBottom)
        return UnevenRoundedRectangle(topLeadingRadius: radii.topLeft,
            bottomLeadingRadius: radii.bottomLeft, bottomTrailingRadius: radii.bottomRight,
            topTrailingRadius: radii.topRight, style: .continuous)
    }

    private func paneRadii(_ frame: CGRect, in viewport: CGRect, squareBottom: Bool) -> SurfaceCornerRadii {
        let inner = SplitTargetingGeometry.paneCornerRadius
        let display = max(inner, layoutContext?.windowCornerRadius ?? 0)
        let corners = SplitWorkspaceGeometry.viewportCorners(of: frame, in: viewport)
        func r(_ corner: CACornerMask) -> CGFloat {
            if squareBottom, corner == .layerMinXMaxYCorner || corner == .layerMaxXMaxYCorner { return 0 }
            return corners.contains(corner) ? display : inner
        }
        return SurfaceCornerRadii(topLeft: r(.layerMinXMinYCorner), topRight: r(.layerMaxXMinYCorner),
            bottomLeft: r(.layerMinXMaxYCorner), bottomRight: r(.layerMaxXMaxYCorner))
    }

    private func splitShadowContours(_ layout: SplitWorkspaceGeometry) -> [SidebarShadowContour] {
        [layout.top, layout.bottom].map { frame in
            SidebarShadowContour(frame: frame.offsetBy(dx: -layout.viewport.minX, dy: -layout.viewport.minY),
                radii: paneRadii(frame, in: layout.viewport,
                    squareBottom: keyboardShortensViewport && abs(frame.maxY - layout.viewport.maxY) < 1))
        }
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
        RoundedRectangle(cornerRadius: SplitTargetingGeometry.paneCornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(selected ? 0.35 : 0.09), lineWidth: selected ? 1.5 : 1)
            // The target guide must not wash over the live Card's colors.
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: selected)
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

    private func updateMinimumSize() {
        browse.updateMinimumCardSize(CGSize(width: minimumWidth, height: minimumHeight))
        lift.minimumCardSize = CGSize(width: minimumWidth, height: minimumHeight)
        secondaryLift.minimumCardSize = CGSize(width: minimumWidth, height: minimumHeight)
        lift.invalidate()
        secondaryLift.invalidate()
    }
}

/// The retained native host reads listing changes inside its installed root.
@MainActor
private struct WorkspaceSplitPickerContent: View {
    let model: AppShellModel

    var body: some View {
        if let split = model.splitWorkspace {
            SplitEmptyPanePicker(summaries: model.recentConversations,
                occupiedID: split.sourceConversationID,
                errorMessage: model.splitOpenError ?? model.recentListingError,
                hasMore: model.recentHasMore,
                onLoadMore: model.loadMoreRecentConversations,
                onRetry: { Task { await model.retrySplitPicker() } },
                onOpen: { id in Task { _ = await model.openInSplitResult(id: id) } },
                onNew: { _ = model.createNewInSplit() })
                .preferredColorScheme(model.appearance.appearance.colorScheme)
        }
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
    let composerDock: WorkspaceComposerDockState
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
        .environment(\.workspaceComposerDock, composerDock)
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
        let keyboard = WorkspaceKeyboardTransitionTrace.shared
        view.readValue = { [weak driver] in
            "\(driver?.nativeInteractionDiagnostic?() ?? "unbound");\(keyboard.diagnostic)"
        }
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

@MainActor
private final class WorkspaceKeyboardTransitionTrace: NSObject {
    static let shared = WorkspaceKeyboardTransitionTrace()

    private(set) var willHideCount = 0
    private(set) var didHideCount = 0
    private(set) var offscreenFrameCount = 0
    private(set) var visibleToHiddenCount = 0
    private(set) var visible = false
    private(set) var visibleHeight: CGFloat = 0

    private override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            center.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
    }

    var diagnostic: String {
        "keyboardTraceWillHide=\(willHideCount);keyboardTraceDidHide=\(didHideCount);keyboardTraceOffscreenFrames=\(offscreenFrameCount);keyboardTraceVisibleToHidden=\(visibleToHiddenCount);keyboardTraceVisible=\(visible);keyboardTraceVisibleHeight=\(Int(visibleHeight.rounded()))"
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        switch notification.name {
        case UIResponder.keyboardWillHideNotification: increment(&willHideCount)
        case UIResponder.keyboardDidHideNotification: increment(&didHideCount)
        case UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification: break
        default: return
        }

        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }).first(where: { $0.isKeyWindow && !$0.isHidden }) else {
            if notification.name == UIResponder.keyboardDidHideNotification { updateVisibility(false, height: 0) }
            return
        }
        if let screen = notification.object as? UIScreen, screen !== window.screen { return }
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            if notification.name == UIResponder.keyboardDidHideNotification { updateVisibility(false, height: 0) }
            return
        }
        let localFrame = window.convert(frame, from: window.screen.coordinateSpace)
        let intersection = window.bounds.intersection(localFrame)
        let height = intersection.isNull ? 0 : max(0, intersection.height)
        let isVisible = height > window.safeAreaInsets.bottom + 1
        if height <= window.safeAreaInsets.bottom + 1 { increment(&offscreenFrameCount) }
        updateVisibility(isVisible, height: height)
    }

    private func updateVisibility(_ next: Bool, height: CGFloat) {
        if visible && !next { increment(&visibleToHiddenCount) }
        visible = next
        visibleHeight = height
    }

    private func increment(_ value: inout Int) {
        if value < 9_999 { value += 1 }
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
