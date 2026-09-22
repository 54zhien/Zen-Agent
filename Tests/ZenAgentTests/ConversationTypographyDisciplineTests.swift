import Foundation
import Testing

@testable import ZenAgent

/// Product invariant: **conversation text is never given a face or a point size directly.**
///
/// Every role resolves through the Typography token layer, and that layer is the only
/// place a face name or a size exists. A view that names its own font is a second,
/// silently-drifting typography system — and on this project it is also invisible: there
/// is no local toolchain and no design review pass, so nothing else would notice.
///
/// These are static gates over the repository's own source. They read files rather than
/// run views, which is the point: this is the one check that does not need a simulator,
/// and the Blueprint's typography rule has no other mechanical guard.
///
/// ## Why the sources are normalised
///
/// Matching is done on the source with **all whitespace removed**, so a forbidden
/// spelling split across lines — `.font(` and then `.system` on the next one — is still
/// one substring after normalisation. Without that step the gate is defeated by pressing
/// return, which is exactly the kind of bypass a mechanical gate is worth having.
@Suite("Conversation typography discipline")
struct ConversationTypographyDisciplineTests {

    private static let conversationDirectory = "App/Conversation"
    private static let viewFile = "ConversationTimelineView.swift"

    /// Spellings that mean someone bypassed the token layer.
    ///
    /// The first two create a face from a name; the third asks the system for a size. The
    /// list is not the whole rule — `noFontIsAppliedOutsideTheTokenLayer` covers the rest —
    /// but it names the three that are easy to write by accident.
    private static let forbiddenSpellings = ["Font.custom(", "UIFont(name:", ".font(.system"]

    /// Every `.swift` file in `App/Conversation/`, as name and whitespace-stripped source.
    ///
    /// Returns `nil` when the repository root cannot be found, and the callers record that
    /// as a failure rather than skipping: a gate that cannot find its subject and passes
    /// anyway is indistinguishable from a gate that found nothing wrong.
    private func conversationSources() -> [(name: String, normalized: String)]? {
        guard let root = repositoryRoot() else { return nil }

        let directory = root.appending(path: Self.conversationDirectory)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        return contents
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> (name: String, normalized: String)? in
                guard let data = try? Data(contentsOf: url) else {
                    // A source that exists but cannot be read is not a source that is
                    // clean. Dropping it here without a word would make "unreadable" and
                    // "nothing to complain about" produce the same report — the exact
                    // confusion this suite was written to avoid, so it is reported even
                    // though the check itself carries on with the files it did read.
                    Issue.record("could not read \(url.path) while checking typography discipline")
                    return nil
                }
                let source = String(decoding: data, as: UTF8.self)
                return (url.lastPathComponent, Self.normalized(source))
            }
    }

    /// All whitespace removed, so a spelling split across lines is still one substring.
    private static func normalized(_ source: String) -> String {
        source.filter { !$0.isWhitespace }
    }

    /// Walks up from this file until a directory holds both `App/` and `Tests/`.
    ///
    /// Not a fixed number of levels. The checkout's absolute path is not this repository's
    /// to choose — CI clones wherever it likes — so a hard-coded depth would quietly point
    /// at the wrong directory in another layout, and "pointed at the wrong place" and
    /// "found nothing to complain about" look identical in a test report.
    private func repositoryRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        for _ in 0..<8 {
            var isDirectory: ObjCBool = false
            let hasApp = FileManager.default.fileExists(
                atPath: directory.appending(path: "App").path, isDirectory: &isDirectory
            ) && isDirectory.boolValue
            let hasTests = FileManager.default.fileExists(
                atPath: directory.appending(path: "Tests").path, isDirectory: &isDirectory
            ) && isDirectory.boolValue

            if hasApp && hasTests { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("the conversation directory exists and holds the layout, its model, and its reader")
    func conversationSourcesExist() {
        guard let sources = conversationSources() else {
            Issue.record(
                """
                could not locate \(Self.conversationDirectory) by walking up from #filePath. \
                Either the repository root has no App/ and Tests/ sibling directories, or the \
                path is more than 8 levels deep — the gate must not pass by finding nothing.
                """
            )
            return
        }

        #expect(
            sources.count >= 3,
            "expected at least 3 sources (the timeline model, its loader and its view); found \(sources.map(\.name))"
        )
    }

    @Test("no conversation source names a face or a system font")
    func noForbiddenSpellingAppears() {
        guard let sources = conversationSources() else {
            Issue.record("could not locate \(Self.conversationDirectory) from #filePath")
            return
        }

        #expect(!sources.isEmpty, "a sweep with nothing to sweep proves nothing")
        for source in sources {
            for spelling in Self.forbiddenSpellings {
                #expect(
                    !source.normalized.contains(spelling),
                    """
                    \(source.name) contains \(spelling). Conversation text goes through the \
                    Typography token layer; naming a face or asking the system for a size here \
                    is a second typography system nothing else would check.
                    """
                )
            }
        }
    }

    @Test("every font in the conversation sources comes from the token layer")
    func noFontIsAppliedOutsideTheTokenLayer() {
        guard let sources = conversationSources() else {
            Issue.record("could not locate \(Self.conversationDirectory) from #filePath")
            return
        }

        #expect(!sources.isEmpty, "a sweep with nothing to sweep proves nothing")
        // Remove the one legitimate application — `.font(Typography.font(for: …))` — and
        // then require that no `.font(` is left. The removal takes the receiver's own
        // `.font(` with it, which is deliberate: it is why this is a removal rather than a
        // count, since one application contains two occurrences of `.font(`.
        for source in sources {
            let withoutTokenApplications = source.normalized
                .replacingOccurrences(of: ".font(Typography.font(", with: "")
            #expect(
                !withoutTokenApplications.contains(".font("),
                """
                \(source.name) applies a font that does not come from Typography. The rule is \
                not "avoid three spellings" but "every text names a role": a system style or a \
                font value built elsewhere is the same bypass, only quieter.
                """
            )
        }

        // And the view must actually be using the layer — an empty directory or a view that
        // never applies a font would satisfy the check above by having nothing to sweep.
        let view = sources.first { $0.name == Self.viewFile }
        guard let view else {
            Issue.record(
                "\(Self.viewFile) is missing from \(Self.conversationDirectory) (found \(sources.map(\.name)))"
            )
            return
        }
        #expect(
            view.normalized.contains("Typography.font(for:"),
            "\(Self.viewFile) must resolve its text through the Typography token layer"
        )
    }
}
