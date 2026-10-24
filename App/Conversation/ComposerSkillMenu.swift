import UIKit

@MainActor
enum ComposerSkillMenu {
    struct Owner: Equatable, Sendable {
        let conversationID: String
        let target: ConversationComposerConfiguration?
    }

    static func make(load: @escaping @Sendable () async throws -> [ComposerSkillOption],
                     currentSelection: @escaping @MainActor () -> [String]?,
                     select: @escaping @MainActor (String?) -> Void) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                let options: [ComposerSkillOption]
                do { options = try await load() }
                catch {
                    guard currentSelection() != nil else { completion([]); return }
                    completion([UIAction(title: "暂时无法读取，请重新打开", attributes: .disabled) { _ in }])
                    return
                }
                guard let selected = currentSelection() else { completion([]); return }
                var actions: [UIMenuElement] = [UIAction(title: "自动选择",
                    state: selected.isEmpty ? .on : .off) { _ in
                    guard currentSelection() != nil else { return }
                    select(nil)
                }]
                for option in options {
                    let isSelected = selected.contains(option.id)
                    let disabled = !isSelected && (!option.isAvailable || selected.count >= SkillRouter.maximumActivatedSkills)
                    let action = UIAction(title: option.name,
                        attributes: disabled ? .disabled : [], state: isSelected ? .on : .off) { _ in
                        guard currentSelection() != nil else { return }
                        select(option.id)
                    }
                    if !option.isAvailable { action.subtitle = "依赖不可用" }
                    actions.append(action)
                }
                if options.isEmpty {
                    actions.append(UIAction(title: "在设置中启用 Skill", attributes: .disabled) { _ in })
                }
                completion(actions)
            }
        }
        return UIMenu(title: "插件", image: UIImage(systemName: "puzzlepiece"), children: [deferred])
    }
}
