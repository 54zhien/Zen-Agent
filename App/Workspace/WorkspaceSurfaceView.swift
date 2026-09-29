import SwiftUI
import UIKit

private struct SurfaceLiftControllerKey: EnvironmentKey {
    static let defaultValue: SurfaceLiftController? = nil
}

private struct SurfaceBrowseControllerKey: EnvironmentKey {
    static let defaultValue: AppSpaceBrowseController? = nil
}

extension EnvironmentValues {
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
    private let model: AppShellModel?
    @State private var lift: SurfaceLiftController
    @State private var browse = AppSpaceBrowseController()
    @ScaledMetric(relativeTo: .body) private var minimumWidth = 220.0
    @ScaledMetric(relativeTo: .body) private var minimumHeight = 300.0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(model: AppShellModel? = nil, liftController: SurfaceLiftController = SurfaceLiftController(),
         @ViewBuilder content: () -> Content) {
        _lift = State(initialValue: liftController)
        self.model = model
        self.content = content()
    }

    var body: some View {
#if DEBUG
        let _ = AppSpaceBrowseController.trace("body presented=\(model?.previewContent.isPresented == true) browse=\(browse.isPresented)")
#endif
        ZStack(alignment: .topLeading) {
            Color(white: 0.035)
            if model?.previewContent.isPresented == true, let layout = browse.layout() {
                ForEach(layout.cards.filter { $0.item != browse.state.selected }, id: \.item) { card in
                    projectedCard(card)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .opacity(card.opacity)
                        .position(x: card.frame.midX, y: card.frame.midY)
                        .zIndex(4 - card.depth)
                }
            }
            ConversationSurfaceHost(liftController: lift, browseController: model == nil ? nil : browse) {
                content.environment(\.surfaceLiftController, lift)
                    .environment(\.surfaceBrowseController, model == nil ? nil : browse)
            }
            .zIndex(4 - (browse.layout()?.cards.first { $0.item == browse.state.selected }?.depth ?? 0))
#if DEBUG
            if ProcessInfo.processInfo.environment["ZEN_SURFACE_LIFT_UI_TEST"] == "1"
                || ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1" {
                SurfaceLiftStateProbe(phase: lift.state.phase)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
#endif
        }
        .ignoresSafeArea()
        .onAppear {
            if let model {
                let browseController = browse
                browse.configure(reader: { [weak model] id in
                    guard let model else { throw PersistenceError.conversationNotFound(id) }
                    return try model.browseWindow(id: id)
                })
                lift.configurePreview(
                    enter: { [weak model, weak browseController] in
                        guard let model, let browseController, model.enterPreview() else { return false }
                        browseController.present(originID: model.conversationID, fallback: model.previewContent.summaries)
                        model.previewContent.releaseSummaryWindow()
                        return true
                    },
                    prepare: { [weak model, weak browseController] in
                        browseController?.cancel()
                        return await model?.preparePreviewReturn(to: browseController?.selectedConversationID) ?? false
                    },
                    commit: { [weak model] in model?.commitPreviewReturn() ?? false },
                    cancel: { [weak model] in model?.cancelPreviewReturn() },
                    isPresented: { [weak model] in model?.previewContent.isPresented ?? false },
                    label: { [weak model, weak browseController] in
                        guard let model, let browseController else { return "当前会话" }
                        return Self.cardLabel(model: model, browse: browseController)
                    })
                if model.previewContent.isPresented {
                    browse.present(originID: model.conversationID, fallback: model.previewContent.summaries)
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
        .onChange(of: cardLabel) { _, _ in lift.refreshCardAccessibility() }
        .onChange(of: model?.previewContent.isPresented) { _, presented in
            if presented != true { browse.finish() }
        }
        .onChange(of: dynamicTypeSize) { _, _ in updateMinimumSize() }
        .onChange(of: scenePhase) { _, phase in
#if DEBUG
            AppSpaceBrowseController.trace("scene \(phase)")
#endif
            if phase != .active { browse.cancel(); lift.invalidate() }
        }
    }

    private var cardLabel: String {
        guard let model else { return "当前会话" }
        return Self.cardLabel(model: model, browse: browse)
    }

    private static func cardLabel(model: AppShellModel, browse: AppSpaceBrowseController) -> String {
        let status = model.previewContent.status(for: browse.selectedConversationID,
            summary: browse.currentSummary, summaryError: browse.errorMessage)
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
            status: summary?.contentUnavailable == true ? .contentUnavailable : .ready)
            .frame(width: max(1, size.width - insets.left - insets.right),
                height: max(1, size.height - insets.top - insets.bottom))
            .padding(EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
            .scaleEffect(pose?.scale ?? 1)
            .frame(width: card.frame.width, height: card.frame.height)
            .clipShape(RoundedRectangle(cornerRadius: card.cornerRadius, style: .continuous))
    }

    private func updateMinimumSize() {
#if DEBUG
        AppSpaceBrowseController.trace("minimum size")
#endif
        browse.updateMinimumCardSize(CGSize(width: minimumWidth, height: minimumHeight))
        lift.minimumCardSize = CGSize(width: minimumWidth, height: minimumHeight)
        lift.invalidate()
    }
}

#if DEBUG
private struct SurfaceLiftStateProbe: UIViewRepresentable {
    let phase: SurfaceLiftState.Phase
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "surface-lift-state-probe"
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityValue = String(describing: phase)
    }
}

@MainActor
struct SurfaceLiftUITestFixture: View {
    var body: some View {
        WorkspaceSurfaceView { ConversationPaneReadingUITestFixtureView() }
    }
}
#endif
