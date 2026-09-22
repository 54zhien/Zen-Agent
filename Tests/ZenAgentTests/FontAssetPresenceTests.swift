import CoreText
import Testing
import UIKit

@testable import ZenAgent

/// Proves the typefaces the Typography layer names are reachable at runtime, and that the
/// two properties the design depends on actually hold: the content face covers CJK and is
/// variable, the interface and code faces do not cover CJK (which is what makes "fall back
/// to the system font" a requirement rather than an observation).
///
/// This file deliberately touches **only system APIs** — no `FontRegistry`, no `Typography`.
/// It has to compile and run against a tree where the font wiring does not exist yet, so that
/// a red result here means "the asset is not reachable", not "the test could not be built".
@Suite("Font asset presence")
struct FontAssetPresenceTests {

    /// The manifest, restated here rather than imported from `FontRegistry`, for the reason
    /// above. If the two ever disagree, that is itself the defect.
    private static let manifestFileNames = [
        "Anthropic Sans.ttf",
        "SourceHanSerifSC-VF.ttf",
        "JetBrainsMono-Regular.ttf",
    ]

    /// PostScript names, hardcoded from `Resources/Fonts/README.md` — which records them as
    /// *expected*, read out of the binaries' `name` tables. Verified against the binaries, not
    /// against the file names, because the two disagree here (the interface file is named
    /// "Anthropic Sans" but its face is `…WebVariable-TextRegular`).
    private static let interfacePostScriptName = "AnthropicSansWebVariable-TextRegular"
    private static let contentPostScriptName = "SourceHanSerifSCVF-ExtraLight"
    private static let codePostScriptName = "JetBrainsMono-Regular"

    /// `wght` as CoreText tags it: 0x77676874. Spelled out rather than imported so this file
    /// keeps its no-product-code dependency.
    private static let weightAxisIdentifier = 2_003_265_652

    @Test("every manifest font file is inside the app bundle")
    func everyManifestFontIsBundled() {
        for fileName in Self.manifestFileNames {
            let base = (fileName as NSString).deletingPathExtension
            let url = Bundle.main.url(forResource: base, withExtension: "ttf")
            #expect(url != nil, "\(fileName) is not in the app bundle")
        }
    }

    @Test("the interface face registers and has no CJK glyphs")
    func interfaceFaceHasNoCJKGlyphs() {
        guard let font = UIFont(name: Self.interfacePostScriptName, size: 17) else {
            Issue.record("\(Self.interfacePostScriptName) did not resolve to a font")
            return
        }
        #expect(
            covers("中", in: font) == false,
            "the interface face covers CJK, so the Blueprint's system-sans fallback requirement no longer describes it"
        )
    }

    @Test("the content face registers and covers CJK")
    func contentFaceCoversCJK() {
        guard let font = UIFont(name: Self.contentPostScriptName, size: 17) else {
            Issue.record("\(Self.contentPostScriptName) did not resolve to a font")
            return
        }
        #expect(
            covers("中文测试", in: font),
            "the content face does not cover the Chinese it is the content typeface for"
        )
    }

    @Test("the content face is a variable font with a wght axis")
    func contentFaceIsVariable() {
        guard let font = UIFont(name: Self.contentPostScriptName, size: 17) else {
            Issue.record("\(Self.contentPostScriptName) did not resolve to a font")
            return
        }
        guard let axes = CTFontCopyVariationAxes(font as CTFont) else {
            Issue.record("\(Self.contentPostScriptName) exposes no variation axes at all")
            return
        }

        let identifiers: [Int] = (axes as NSArray).compactMap { element in
            guard let axis = element as? NSDictionary else { return nil }
            return axis[kCTFontVariationAxisIdentifierKey as String] as? Int
        }
        #expect(
            identifiers.contains(Self.weightAxisIdentifier),
            "no wght axis among \(identifiers) — the content face cannot carry a chosen body weight"
        )
    }

    @Test("code face registers and has no CJK glyphs")
    func codeFaceHasNoCJKGlyphs() {
        guard let font = UIFont(name: Self.codePostScriptName, size: 17) else {
            Issue.record("\(Self.codePostScriptName) did not resolve to a font")
            return
        }
        #expect(
            covers("中", in: font) == false,
            "the code face covers CJK, so the Blueprint's monospaced-CJK fallback requirement no longer describes it"
        )
    }

    /// True only when **every** UTF-16 unit in `text` has a glyph in `font`.
    ///
    /// `CTFontGetGlyphsForCharacters` is the font's own answer, with no fallback applied — which
    /// is the point: `UIFont(name:size:)` resolves to the named face only, so a false here is
    /// "this face lacks the glyph", not "rendering will show a blank".
    private func covers(_ text: String, in font: UIFont) -> Bool {
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count)
    }
}
