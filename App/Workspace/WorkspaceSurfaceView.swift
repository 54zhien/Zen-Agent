import SwiftUI
import UIKit

private struct SurfaceLiftControllerKey: EnvironmentKey {
    static let defaultValue: SurfaceLiftController? = nil
}

extension EnvironmentValues {
    var surfaceLiftController: SurfaceLiftController? {
        get { self[SurfaceLiftControllerKey.self] }
        set { self[SurfaceLiftControllerKey.self] = newValue }
    }
}

@MainActor
struct WorkspaceSurfaceView<Content: View>: View {
    let content: Content
    private let model: AppShellModel?
    @State private var lift: SurfaceLiftController
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
        ZStack {
            Color(white: 0.035)
            if let model, model.previewContent.isPresented {
                predecessorPreviews(model)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ConversationSurfaceHost(liftController: lift) {
                content.environment(\.surfaceLiftController, lift)
            }
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
                lift.configurePreview(
                    enter: { [weak model] in model?.enterPreview() ?? false },
                    prepare: { [weak model] in await model?.preparePreviewReturn() ?? false },
                    commit: { [weak model] in model?.commitPreviewReturn() ?? false },
                    cancel: { [weak model] in model?.cancelPreviewReturn() },
                    isPresented: { [weak model] in model?.previewContent.isPresented ?? false },
                    label: { [weak model] in
                        guard let model else { return "当前会话" }
                        return model.previewContent.accessibilityLabel
                    })
            }
            updateMinimumSize()
        }
        .task(id: model?.previewContent.isPresented) {
            guard let model, model.previewContent.isPresented else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard model.previewContent.isPresented else { return }
                model.refreshPreview()
            }
        }
        .onChange(of: model?.previewContent.accessibilityLabel) { _, _ in lift.refreshCardAccessibility() }
        .onChange(of: dynamicTypeSize) { _, _ in updateMinimumSize() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { lift.invalidate() }
        }
    }

    private func predecessorPreviews(_ model: AppShellModel) -> some View {
        GeometryReader { viewport in
            let rows = model.previewContent.summaries
            let ids = Array(rows.map(\.id).reversed())
            let current: AppSpaceGeometry.Item = ids.contains(model.conversationID)
                ? .conversation(model.conversationID) : .newConversation
            let insets = viewport.safeAreaInsets
            if let layout = AppSpaceGeometry.resolve(size: viewport.size,
                safeArea: UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing),
                historyIDs: ids, current: current,
                minimumCardSize: CGSize(width: minimumWidth, height: minimumHeight)) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.cards.filter { $0.depth > 0 }, id: \.item) { card in
                        if case .conversation(let id) = card.item, let row = rows.first(where: { $0.id == id }) {
                            ConversationPreviewView(summary: row)
                                .frame(width: card.frame.width, height: card.frame.height)
                                .clipShape(RoundedRectangle(cornerRadius: card.cornerRadius))
                                .position(x: card.frame.midX, y: card.frame.midY)
                                .zIndex(Double(3 - card.depth))
                        }
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
        }
    }

    private func updateMinimumSize() {
        lift.invalidate()
        lift.minimumCardSize = CGSize(width: minimumWidth, height: minimumHeight)
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
