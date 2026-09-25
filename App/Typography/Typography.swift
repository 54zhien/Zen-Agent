import CoreText
import SwiftUI
import UIKit

/// The conceptual roles from the Blueprint's `3.2 Typography System`. Every surface asks
/// for one of these; no view names a font or a point size directly.
enum TypographyRole: CaseIterable {
    case interfaceTitle
    case interfaceBody
    case interfaceCaption
    case conversationPrompt
    case conversationBody
    case conversationHeading
    case conversationQuote
    case codeInline
    case codeBlock
}

/// Which bundled face a role resolves to.
enum TypographyFace: CaseIterable, Equatable {
    case interface
    case content
    case code

    /// PostScript name of the face's default instance. Verified against the font binaries'
    /// `name` tables (see `Resources/Fonts/README.md`), not inferred from the file name.
    var postScriptName: String {
        switch self {
        case .interface:
            return "AnthropicSansWebVariable-TextRegular"
        case .content:
            return "SourceHanSerifSCVF-ExtraLight"
        case .code:
            return "JetBrainsMono-Regular"
        }
    }
}

/// A resolved design token. Pure data — no UIKit objects — so the mapping is testable
/// without a font environment.
struct TypographyToken: Equatable {
    let face: TypographyFace
    let pointSize: CGFloat
    let textStyle: UIFont.TextStyle
    /// The `wght` axis value to request. `nil` for static faces, which have no axis.
    let weight: CGFloat?
}

enum Typography {

    /// `wght` as the four-byte tag CoreText expects: 0x77676874.
    static let weightAxisIdentifier = NSNumber(value: 2_003_265_652)

    static let variationAttributeName = kCTFontVariationAttribute as UIFontDescriptor.AttributeName

    /// Starter baselines, **not measured results**. The Blueprint marks the interface face's
    /// hierarchy (single weight — title/body/caption can only differ by synthesised bold) and
    /// the content face's body weight as device-calibration items, so treat every number here
    /// as the starting point to tune on a real device, not as a verified visual outcome.
    static func token(for role: TypographyRole) -> TypographyToken {
        switch role {
        case .interfaceTitle:
            return TypographyToken(face: .interface, pointSize: 20, textStyle: .title3, weight: nil)
        case .interfaceBody:
            return TypographyToken(face: .interface, pointSize: 17, textStyle: .body, weight: nil)
        case .interfaceCaption:
            return TypographyToken(face: .interface, pointSize: 13, textStyle: .caption1, weight: nil)
        case .conversationPrompt:
            return TypographyToken(face: .content, pointSize: 16, textStyle: .body, weight: 400)
        case .conversationBody:
            return TypographyToken(face: .content, pointSize: 16, textStyle: .body, weight: 400)
        case .conversationHeading:
            return TypographyToken(face: .content, pointSize: 20, textStyle: .title3, weight: 600)
        case .conversationQuote:
            return TypographyToken(face: .content, pointSize: 16, textStyle: .body, weight: 400)
        case .codeInline:
            return TypographyToken(face: .code, pointSize: 15, textStyle: .footnote, weight: nil)
        case .codeBlock:
            return TypographyToken(face: .code, pointSize: 15, textStyle: .body, weight: nil)
        }
    }

    static func readingSpacing(for role: TypographyRole) -> (tracking: CGFloat, lineSpacing: CGFloat) {
        switch role {
        case .conversationPrompt, .conversationBody, .conversationQuote:
            return (tracking: 0.5, lineSpacing: 3)
        default:
            return (tracking: 0, lineSpacing: 0)
        }
    }

    /// The UIKit-facing entry point, and the only place a face name or a variation is built.
    static func uiFont(
        for role: TypographyRole,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        let token = token(for: role)
        #if ZEN_DEVICE_TEST
        // Public CI artifacts cannot include the development-only interface font.
        // Keep content/code typography intact while the device build uses System Sans.
        if token.face == .interface {
            let base = UIFont.systemFont(ofSize: token.pointSize)
            return UIFontMetrics(forTextStyle: token.textStyle)
                .scaledFont(for: base, compatibleWith: traits)
        }
        #endif
        let base = UIFont(descriptor: descriptor(for: token), size: token.pointSize)
        let scaled = UIFontMetrics(forTextStyle: token.textStyle)
            .scaledFont(for: base, compatibleWith: traits)

        guard let weight = token.weight else { return scaled }

        // Re-apply the variation instead of assuming `scaledFont(for:)` preserved it. Whether
        // UIKit carries a variation attribute through scaling is not documented anywhere this
        // repository can cite, and the applied weight is a design requirement (the Blueprint
        // forbids relying on the file's default axis value), so it is asserted after scaling
        // as well. `size: 0` keeps the descriptor's own point size.
        let redressed = scaled.fontDescriptor.addingAttributes([
            variationAttributeName: [weightAxisIdentifier: NSNumber(value: Double(weight))]
        ])
        return UIFont(descriptor: redressed, size: 0)
    }

    /// The SwiftUI-facing entry point.
    ///
    /// Guarantees the same point size the UIKit path computes for `traits`. It does **not**
    /// guarantee that SwiftUI re-evaluates this call when the user changes the system text
    /// size — `Font` carries no environment dependency here, unlike
    /// `Font.custom(_:size:relativeTo:)`, which is the native path but cannot express a
    /// `wght` axis. The Blueprint requires an explicit body weight, so the axis wins and the
    /// re-evaluation question is settled on device, not here. Call sites that already hold a
    /// `DynamicTypeSize` should use the overload below, which re-derives the size per value.
    static func font(
        for role: TypographyRole,
        compatibleWith traits: UITraitCollection? = nil
    ) -> Font {
        Font(uiFont(for: role, compatibleWith: traits) as CTFont)
    }

    /// Convenience for SwiftUI call sites, which hold a `DynamicTypeSize`, not a trait collection.
    static func font(for role: TypographyRole, dynamicTypeSize: DynamicTypeSize) -> Font {
        font(for: role, compatibleWith: UITraitCollection(
            preferredContentSizeCategory: contentSizeCategory(for: dynamicTypeSize)
        ))
    }

    /// Total mapping, no `fatalError` path. `default` (rather than an exhaustive list) keeps
    /// this source-compatible if SwiftUI adds cases.
    static func contentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall:
            return .extraSmall
        case .small:
            return .small
        case .medium:
            return .medium
        case .large:
            return .large
        case .xLarge:
            return .extraLarge
        case .xxLarge:
            return .extraExtraLarge
        case .xxxLarge:
            return .extraExtraExtraLarge
        case .accessibility1:
            return .accessibilityMedium
        case .accessibility2:
            return .accessibilityLarge
        case .accessibility3:
            return .accessibilityExtraLarge
        case .accessibility4:
            return .accessibilityExtraExtraLarge
        case .accessibility5:
            return .accessibilityExtraExtraExtraLarge
        default:
            return .large
        }
    }

    private static func descriptor(for token: TypographyToken) -> UIFontDescriptor {
        var attributes: [UIFontDescriptor.AttributeName: Any] = [
            .name: token.face.postScriptName
        ]
        if let weight = token.weight {
            attributes[variationAttributeName] = [
                weightAxisIdentifier: NSNumber(value: Double(weight))
            ]
        }
        return UIFontDescriptor(fontAttributes: attributes)
    }
}
