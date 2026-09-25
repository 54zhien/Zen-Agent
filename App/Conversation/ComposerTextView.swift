/// Prevent SwiftUI projection updates from overwriting an in-progress IME composition.
struct ComposerTextViewUpdatePolicy: Equatable {
    let writesText: Bool
    let writesSelection: Bool

    static func resolve(markedTextPresent: Bool) -> Self {
        Self(writesText: !markedTextPresent, writesSelection: !markedTextPresent)
    }
}
