import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class ComposerActionMenuState {
    var suspensionRevision = 0
    var isSuspended = false
    var activeLevel: ComposerActionMenuLevel = .actions
    var models: [ModelDescriptor] = []
    var selectedModelID: ModelID?
    var skillOptions: [ComposerSkillOption] = []
    var selectedSkillIDs: [String] = []
    var isLoadingSkills = false
    var skillLoadFailed = false
    var skillLoadRevision = 0
    var skillSelectionOwner: ComposerSkillMenu.Owner?
    @ObservationIgnored var loadSkills: @Sendable () async throws -> [ComposerSkillOption] = { [] }
    @ObservationIgnored var currentSkillSelection: () -> [String]? = { nil }
    @ObservationIgnored var onSkill: (String?) -> Void = { _ in }
    var supportedThinkingEfforts: [ThinkingEffort] = []
    var selectedThinkingEffort: ThinkingEffort?
    var defaultThinkingEffort: ThinkingEffort?
    // Visual target only: never participates in request configuration or labels.
    var previewThinkingEffort: ThinkingEffort?
    var thinkingIconLevel: ThinkingEffort? {
        if let previewThinkingEffort, supportedThinkingEfforts.contains(previewThinkingEffort) {
            return previewThinkingEffort
        }
        return thinkingLevel
    }
    @ObservationIgnored var onSelectThinking: (ThinkingEffort?) -> Void = { _ in }

    var thinkingLevel: ThinkingEffort? {
        if let selectedThinkingEffort { return selectedThinkingEffort }
        return defaultLevel
    }

    var defaultLevel: ThinkingEffort? {
        guard let defaultThinkingEffort, supportedThinkingEfforts.contains(defaultThinkingEffort) else { return nil }
        return defaultThinkingEffort
    }

    func resetSkills() {
        skillOptions = []
        isLoadingSkills = false
        skillLoadFailed = false
        skillLoadRevision += 1
    }

    func loadSkillOptions() async {
        guard !isLoadingSkills, let owner = skillSelectionOwner,
              currentSkillSelection() != nil else { return }
        isLoadingSkills = true
        skillLoadFailed = false
        let load = loadSkills
        defer {
            if skillSelectionOwner == owner { isLoadingSkills = false }
        }
        do {
            let options = try await load()
            guard skillSelectionOwner == owner, let selected = currentSkillSelection() else { return }
            skillOptions = options
            selectedSkillIDs = selected
        } catch {
            guard skillSelectionOwner == owner, currentSkillSelection() != nil else { return }
            skillLoadFailed = true
        }
    }

    func selectSkill(_ id: String?) {
        guard skillSelectionOwner != nil, let selected = currentSkillSelection() else { return }
        if let id {
            guard let option = skillOptions.first(where: { $0.id == id }) else { return }
            let alreadySelected = selected.contains(id)
            guard alreadySelected || (option.isAvailable && selected.count < SkillRouter.maximumActivatedSkills) else {
                return
            }
        }
        onSkill(id)
    }
}

enum ComposerActionMenuLevel: Equatable {
    case actions, models, thinking, plugins, images, files

    var title: String {
        switch self {
        case .actions: "更多操作"
        case .models: "模型"
        case .thinking: "思考"
        case .plugins: "插件"
        case .images: "图片"
        case .files: "文件"
        }
    }

    var isImplemented: Bool {
        self != .images && self != .files
    }
}

struct ComposerActionMenuView: View {
    let presentation: ComposerActionMenuState
    let maximumSize: CGSize
    let onOpen: (ComposerActionMenuLevel) -> Void
    var keyboardSheet = false
    var cornerRadius: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var iconDiameter: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var floatingRowHeight: CGFloat = 64

    private var iconCenter: CGFloat { max(cornerRadius, iconDiameter / 2 + 12) }
    private var rowHeight: CGFloat {
        keyboardSheet ? max(iconDiameter + 8, (maximumSize.height - 2 * iconCenter) / 4) : floatingRowHeight
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }.scrollBounceBehavior(.basedOnSize)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .frame(width: maximumSize.width)
        .frame(height: keyboardSheet ? maximumSize.height : nil)
        .frame(maxHeight: maximumSize.height)
        .fixedSize(horizontal: false, vertical: !keyboardSheet)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-action-menu")
        .accessibilityHidden(presentation.activeLevel != .actions)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            row(.models)
            row(.thinking)
            row(.plugins)
            row(.images)
            row(.files)
        }
        .padding(.vertical, max(0, iconCenter - rowHeight / 2))
        .frame(width: maximumSize.width)
    }

    private func row(_ level: ComposerActionMenuLevel) -> some View {
        Button { onOpen(level) } label: {
            HStack(spacing: 12) {
                ComposerMenuSymbol(level: level, thinking: presentation.thinkingIconLevel,
                                   supportedLevels: presentation.supportedThinkingEfforts)
                    .frame(width: 25, height: 25)
                    .frame(width: iconDiameter, height: iconDiameter)
                    .background(Color(uiColor: .secondarySystemFill), in: Circle())
                    .accessibilityHidden(true)
                Text(level.title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).accessibilityHidden(true)
            }
            .padding(.leading, iconCenter - iconDiameter / 2)
            .padding(.trailing, 24)
            .padding(.vertical, 4)
            .frame(minHeight: rowHeight)
            .contentShape(Rectangle())
        }
        .disabled(presentation.activeLevel != .actions)
        .disabled(!level.isImplemented)
        .opacity(level.isImplemented ? 1 : 0.48)
        .accessibilityLabel(level.title)
        .accessibilityValue(level == .thinking ? (presentation.thinkingLevel?.title ?? "模型默认") : "")
    }
}
