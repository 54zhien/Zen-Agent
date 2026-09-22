import CoreText
import Foundation

/// Registers the bundled typefaces with CoreText.
///
/// `Info.plist`'s `UIAppFonts` already asks UIKit to register these at launch, so on a
/// healthy build the explicit call below finds each face **already registered** and must
/// treat that as success: `CTFontManagerRegisterFontsForURL` reports it as an error
/// (`kCTFontManagerErrorAlreadyRegistered`), and an implementation that treated any `false`
/// as failure would throw on every single launch. The explicit path exists so that a missing
/// asset fails loudly at the one place that can name the file, instead of text silently
/// rendering in a fallback face — which is the failure this project cannot see, because the
/// build machine has no Swift toolchain and only CI can answer.
enum FontRegistry {

    enum RegistrationError: Error, Equatable {
        case missingBundledFont(String)
        case registrationFailed(String, code: Int)
    }

    /// The manifest. Every file must be present in the bundle.
    static let bundledFontFileNames: [String] = [
        "Anthropic Sans.ttf",
        "SourceHanSerifSC-VF.ttf",
        "JetBrainsMono-Regular.ttf",
    ]

    /// Registers every bundled font. Throws on the first file that is missing from the
    /// bundle, or that CoreText refuses for a reason other than "already registered".
    ///
    /// Idempotent by contract: calling it twice must not throw.
    static func registerBundledFonts(in bundle: Bundle = .main) throws {
        for fileName in bundledFontFileNames {
            try register(fileName, in: bundle)
        }
    }

    private static func register(_ fileName: String, in bundle: Bundle) throws {
        let base = (fileName as NSString).deletingPathExtension
        guard let url = bundle.url(forResource: base, withExtension: "ttf") else {
            throw RegistrationError.missingBundledFont(fileName)
        }

        var unmanaged: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanaged)
        if registered { return }

        let code = unmanaged.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
        if code == CTFontManagerError.alreadyRegistered.rawValue { return }
        throw RegistrationError.registrationFailed(fileName, code: code)
    }
}
