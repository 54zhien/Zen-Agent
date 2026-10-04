import SwiftUI

@MainActor
struct SettingsCloseControl {
    let focus: SettingsInputFocus
    let blocked: Bool
    let close: () -> Void
}

private struct SettingsCloseControlKey: EnvironmentKey {
    static let defaultValue: SettingsCloseControl? = nil
}

extension EnvironmentValues {
    var settingsCloseControl: SettingsCloseControl? {
        get { self[SettingsCloseControlKey.self] }
        set { self[SettingsCloseControlKey.self] = newValue }
    }
}

@MainActor
private struct SettingsCloseToolbarModifier: ViewModifier {
    @Environment(\.settingsCloseControl) private var control
    func body(content: Content) -> some View {
        content.toolbar {
            if let control {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { control.focus.release(then: control.close) }
                        .disabled(control.blocked || control.focus.hasMarkedText || control.focus.isClosing)
                        .accessibilityIdentifier("settings-close")
                }
            }
        }
    }
}

extension View {
    /// Navigation destinations publish their own toolbar preferences. Each page
    /// presents the same overlay-owned exit rather than a separate close owner.
    func settingsCloseToolbar() -> some View { modifier(SettingsCloseToolbarModifier()) }
}
