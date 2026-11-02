import SwiftUI

struct ComposerMenuDetailView: View {
    var compactThinking = false
    let level: ComposerActionMenuLevel
    let presentation: ComposerActionMenuState
    let onSelect: (ModelID) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ComposerMenuSymbol(level: level, thinking: presentation.thinkingIconLevel,
                                   supportedLevels: presentation.supportedThinkingEfforts)
                    .frame(width: 25, height: 25)
                    .frame(width: 44, height: 44)
                    .background(Color(uiColor: .secondarySystemFill), in: Circle())
                Text(level.title).font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).background(.quaternary, in: Circle())
                }
                .accessibilityLabel("关闭，返回一级菜单")
            }
            .padding(.horizontal, 24).padding(.top, 0).padding(.bottom, 8)
            switch level {
            case .models: models
            case .thinking:
                if presentation.supportedThinkingEfforts.isEmpty {
                    information("当前模型不支持调整思考档位", detail: "思考方式由模型决定，你可以切换模型查看可用档位。")
                } else {
                    ComposerThinkingControl(presentation: presentation, compactLayout: compactThinking)
                }
            case .plugins:
                skills
            case .images:
                information("图片附件尚未接入", detail: "当前版本暂不支持从此处添加图片。")
            case .files:
                information("文件附件尚未接入", detail: "当前版本暂不支持从此处添加文件。")
            case .actions: EmptyView()
            }
        }
        .font(.body).foregroundStyle(.primary).buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-detail-\(String(describing: level))")
        .task(id: presentation.skillLoadRevision) {
            guard level == .plugins else { return }
            await presentation.loadSkillOptions()
        }
    }

    private var models: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择本次对话的模型").font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                if presentation.models.isEmpty {
                    Text("暂无可用模型，请先在设置中配置 Provider。")
                        .foregroundStyle(.secondary).padding(24)
                }
                ForEach(presentation.models, id: \.id) { model in
                    Button { onSelect(model.id) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName)
                                Text(model.supportedThinkingEfforts.isEmpty ? "模型自动思考" :
                                        model.supportedThinkingEfforts.map(\.title).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark").font(.body.weight(.semibold))
                                .opacity(model.id == presentation.selectedModelID ? 1 : 0)
                        }
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .frame(minHeight: 52)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemFill))
                                .opacity(model.id == presentation.selectedModelID ? 1 : 0)
                                .padding(.horizontal, 12)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(model.id == presentation.selectedModelID ? .isSelected : [])
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var skills: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择本次对话使用的插件").font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                Button { presentation.selectSkill(nil) } label: {
                    skillRow(title: "自动选择", selected: presentation.selectedSkillIDs.isEmpty)
                }
                .accessibilityAddTraits(presentation.selectedSkillIDs.isEmpty ? .isSelected : [])
                if presentation.isLoadingSkills {
                    Text("正在读取可用插件…")
                        .foregroundStyle(.secondary).padding(24)
                } else if presentation.skillLoadFailed {
                    Text("暂时无法读取，请关闭后重新打开。")
                        .foregroundStyle(.secondary).padding(24)
                } else if presentation.skillOptions.isEmpty {
                    Text("在设置中启用 Skill")
                        .foregroundStyle(.secondary).padding(24)
                }
                ForEach(presentation.skillOptions, id: \.id) { option in
                    let selected = presentation.selectedSkillIDs.contains(option.id)
                    Button { presentation.selectSkill(option.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            skillRow(title: option.name, selected: selected)
                            if !option.isAvailable {
                                Text("依赖不可用").font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 24).padding(.bottom, 8)
                            }
                        }
                    }
                    .disabled(!selected && (!option.isAvailable
                        || presentation.selectedSkillIDs.count >= SkillRouter.maximumActivatedSkills))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityValue(option.isAvailable ? "" : "依赖不可用")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func skillRow(title: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func information(_ title: String, detail: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(28)
        }
    }
}
