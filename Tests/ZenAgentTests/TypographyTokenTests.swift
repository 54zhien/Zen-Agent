import CoreText
import Testing
import UIKit

@testable import ZenAgent

/// Pins the token layer: which face, size, text style and `wght` each conceptual role
/// resolves to, and — the part that is not decidable by reading the source — whether the
/// variation a token asks for survives building a `UIFont` and, after that, a `CTFont`.
///
/// What these tests can and cannot settle is worth stating, because the difference is where
/// the remaining risk lives. They settle the **arithmetic and the state**: the mapping from
/// role to numbers, that scaling with a larger content size category produces a larger point
/// size, and that CoreText's resolved font still reports the requested axis value. They do
/// **not** settle the rendered result — CoreText publishes no API that reports the visual
/// weight of a rasterised instance — nor whether SwiftUI re-evaluates a token when the user
/// changes the system text size. Those stay device-calibration items.
@Suite("Typography tokens")
struct TypographyTokenTests {

    @Test("the nine conceptual roles all resolve to a token")
    func everyRoleResolves() {
        #expect(TypographyRole.allCases.count == 9)
        for role in TypographyRole.allCases {
            let token = Typography.token(for: role)
            #expect(token.pointSize > 0, "\(role) must have a positive point size")
            #expect(
                token.face.postScriptName.isEmpty == false,
                "\(role) must name a face"
            )
        }
    }

    @Test("each role maps to its declared face, size, text style and weight")
    func roleMappingIsExplicit() {
        // Written out rather than derived from the implementation: a table that agreed with
        // the code by construction would pass no matter which numbers the code chose.
        let expected: [(TypographyRole, TypographyFace, CGFloat, UIFont.TextStyle, CGFloat?)] = [
            (.interfaceTitle, .interface, 20, .title3, nil),
            (.interfaceBody, .interface, 17, .body, nil),
            (.interfaceCaption, .interface, 13, .caption1, nil),
            (.conversationPrompt, .content, 17, .body, 400),
            (.conversationBody, .content, 17, .body, 400),
            (.conversationHeading, .content, 20, .title3, 600),
            (.conversationQuote, .content, 17, .body, 400),
            (.codeInline, .code, 15, .footnote, nil),
            (.codeBlock, .code, 15, .body, nil),
        ]
        #expect(expected.count == TypographyRole.allCases.count)

        for (role, face, pointSize, textStyle, weight) in expected {
            let token = Typography.token(for: role)
            #expect(token.face == face, "\(role) face")
            #expect(token.pointSize == pointSize, "\(role) point size")
            #expect(token.textStyle == textStyle, "\(role) text style")
            #expect(token.weight == weight, "\(role) weight")
        }
    }

    @Test("every face resolves to a registered font")
    func everyFaceRegisters() {
        for face in TypographyFace.allCases {
            let font = UIFont(name: face.postScriptName, size: 17)
            #expect(font != nil, "\(face.postScriptName) is not a registered font")
        }
    }

    @Test("interface and code roles carry no weight variation")
    func staticFacesRequestNoVariation() {
        // Neither face has an `fvar` table, so asking for an axis would be asking for
        // something the font cannot answer — and would hide the fact that the interface
        // hierarchy has to come from somewhere else.
        for role in [TypographyRole.interfaceBody, .codeBlock] {
            let stored = Typography.uiFont(for: role).fontDescriptor
                .object(forKey: Typography.variationAttributeName)
            #expect(stored == nil, "\(role) must not request a weight variation")
        }
    }

    @Test("content roles request the explicit body weight")
    func contentRolesCarryExplicitWeight() {
        // The content face is a variable font whose default axis value is 250, which the
        // Blueprint forbids relying on. Read back as an `NSDictionary` and subscripted with
        // the `NSNumber` tag, rather than cast to a Swift dictionary: whether that bridge
        // forms depends on the concrete values inside, and this assertion is about the values.
        let body = Typography.uiFont(for: .conversationBody).fontDescriptor
            .object(forKey: Typography.variationAttributeName) as? NSDictionary
        let bodyWeight = body?[Typography.weightAxisIdentifier] as? NSNumber
        #expect(
            bodyWeight != nil,
            "the content body role must carry a variation attribute of its own"
        )
        #expect(
            bodyWeight?.doubleValue == 400,
            "the content body role must ask for wght 400, not the file's default"
        )

        let heading = Typography.uiFont(for: .conversationHeading).fontDescriptor
            .object(forKey: Typography.variationAttributeName) as? NSDictionary
        let headingWeight = heading?[Typography.weightAxisIdentifier] as? NSNumber
        #expect(
            headingWeight?.doubleValue == 600,
            "the conversation heading role must ask for wght 600"
        )
    }

    @Test("the requested weight survives dynamic type scaling")
    func requestedWeightSurvivesScaling() {
        let accessibilityTraits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let atDefaultSize = Typography.uiFont(for: .conversationBody)
        let atAccessibilitySize = Typography.uiFont(
            for: .conversationBody,
            compatibleWith: accessibilityTraits
        )

        let stored = atAccessibilitySize.fontDescriptor
            .object(forKey: Typography.variationAttributeName) as? NSDictionary
        #expect(
            (stored?[Typography.weightAxisIdentifier] as? NSNumber)?.doubleValue == 400,
            "scaling must not drop the requested weight; the design weight is not optional at large sizes"
        )
        #expect(
            atAccessibilitySize.pointSize > atDefaultSize.pointSize,
            "an accessibility content size category must produce a larger point size, not just a different one"
        )
    }

    @Test("CoreText keeps the requested variation state")
    func coreTextKeepsVariationState() {
        // This asserts that the variation attribute reaches the resolved `CTFont` — it does
        // not assert what the rasterised instance looks like, which CoreText does not expose.
        // If this is the only failure, the finding is that "the descriptor carries the axis"
        // and "CoreText preserves it" are two different claims, and that is worth reporting
        // rather than weakening the assertion.
        let font = Typography.uiFont(for: .conversationBody)
        guard let rawVariation = CTFontCopyVariation(font as CTFont) else {
            Issue.record("CTFontCopyVariation returned nothing for a font built with an explicit wght")
            return
        }
        let variation = rawVariation as NSDictionary
        #expect(
            (variation[Typography.weightAxisIdentifier] as? NSNumber)?.doubleValue == 400,
            "resolved variation state was \(variation)"
        )
    }

    @Test("Dynamic Type mapping is monotonic")
    func dynamicTypeMappingIsMonotonic() {
        #expect(Typography.contentSizeCategory(for: .xSmall) == .extraSmall)
        #expect(Typography.contentSizeCategory(for: .large) == .large)
        #expect(Typography.contentSizeCategory(for: .accessibility5) == .accessibilityExtraExtraExtraLarge)

        let smallest = Typography.uiFont(
            for: .conversationBody,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraSmall)
        )
        let middle = Typography.uiFont(
            for: .conversationBody,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        let largest = Typography.uiFont(
            for: .conversationBody,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )

        #expect(smallest.pointSize < middle.pointSize, "xSmall must be smaller than large")
        #expect(middle.pointSize < largest.pointSize, "large must be smaller than accessibility5")
    }

    @Test("font registration is idempotent")
    func registrationIsIdempotent() throws {
        // `UIAppFonts` has already registered these by the time the test host is running, so
        // the first call is the "already registered is success" path, and the second proves it
        // stays that way. A `false` treated as failure would throw here, on every launch.
        try FontRegistry.registerBundledFonts()
        try FontRegistry.registerBundledFonts()
    }
}
