import Foundation
import Testing

@testable import ZenAgent

@Suite("Conversation session residency")
@MainActor
struct ConversationSessionStoreTests {
    @Test("reopening changes LRU order even when wall clock timestamps tie")
    func tiedClockUsesCommittedAccessOrder() {
        let store = ConversationSessionStore(warmLimit: 2, now: { Fixtures.epoch })
        let a = ConversationSession(conversationID: "a", configuration: nil)
        let b = ConversationSession(conversationID: "b", configuration: nil)
        let c = ConversationSession(conversationID: "c", configuration: nil)
        let d = ConversationSession(conversationID: "d", configuration: nil)
        for session in [a, b, c] {
            store.retain(session, reconstruction: .history(configuration: nil))
            store.activate(session)
        }
        store.activate(a)
        store.retain(d, reconstruction: .history(configuration: nil))
        store.activate(d)
        store.evictIfNeeded(isRuntimeProtected: { _ in false })
        #expect(store.session(for: "b") == nil)
        #expect(store.session(for: "a") === a)
        #expect(store.session(for: "c") === c)
        #expect(store.state(for: "d") == .active)
        #expect(store.state(for: "a") == .warm(lastAccess: Fixtures.epoch))
        #expect(store.state(for: "b") == .evicted)
    }

    @Test("all transient input and reading state survive a zero safe-warm budget",
          arguments: ["text", "selection", "quote", "attachment", "compact", "editing",
                      "composition", "selectionDrag", "quoteDrag", "reading", "configuration"])
    func transientStateIsProtected(kind: String) {
        let store = ConversationSessionStore(warmLimit: 0)
        let session = ConversationSession(conversationID: "protected", configuration: nil)
        let composer = session.composer
        switch kind {
        case "text": composer.draft.text = "draft"
        case "selection": composer.draft.selection = ComposerSelection(range: 1..<1)
        case "quote": composer.draft.references = [QuoteReference(id: "quote",
            source: QuoteSourceLocator(sourceConversationID: "source", sourceMessageID: "message",
                sourcePartID: "part", range: QuoteTextRange(utf16Start: 0, utf16Length: 4)),
            snapshot: "text", createdAt: Fixtures.epoch)]
        case "attachment": composer.draft.attachments = [AttachmentReference(id: "asset",
            versionID: "version", fingerprint: "hash", displayName: "file", kind: .file)]
        case "compact": composer.draft.presentationState = .compact
        case "editing": composer.draft.presentationState = .editing
        case "composition": _ = composer.updateComposition(isComposing: true)
        case "selectionDrag": _ = composer.handle(.selectionHandleDragChanged(true))
        case "quoteDrag": _ = composer.handle(.quoteDragPhaseChanged(.active))
        case "reading": _ = session.readingPosition.apply(.userScrolled(
            geometry: ScrollGeometry(viewportHeight: 100, contentHeight: 500, offset: 0),
            anchor: TurnAnchor(runID: "turn", relativeViewportOffset: 0)))
        case "configuration": composer.configuration = ConversationComposerConfiguration(
            providerInstanceID: ProviderInstanceID(rawValue: "chosen"), modelID: ModelID(rawValue: "model"))
        default: Issue.record("unknown protection scenario")
        }
        store.retain(session, reconstruction: .history(configuration: nil))
        store.activate(ConversationSession(conversationID: "current", configuration: nil))
        store.evictIfNeeded(isRuntimeProtected: { _ in false })
        #expect(store.session(for: "protected") === session)
        #expect(store.state(for: "current") == .active)
    }

    @Test("latest durable configuration determines whether a warm choice is reconstructible")
    func durableChoiceCanChangeAfterInitialOpen() {
        let store = ConversationSessionStore(warmLimit: 0)
        let original = ConversationComposerConfiguration(providerInstanceID: ProviderInstanceID(rawValue: "a"),
            modelID: ModelID(rawValue: "model"))
        let latest = ConversationComposerConfiguration(providerInstanceID: ProviderInstanceID(rawValue: "b"),
            modelID: ModelID(rawValue: "model"))
        let session = ConversationSession(conversationID: "choice", configuration: original)
        store.retain(session, reconstruction: .history(configuration: latest))
        store.activate(ConversationSession(conversationID: "current", configuration: nil))
        store.evictIfNeeded(isRuntimeProtected: { _ in false })
        #expect(store.session(for: "choice") === session)
        session.composer.configuration = latest
        store.evictIfNeeded(isRuntimeProtected: { _ in false })
        #expect(store.session(for: "choice") == nil)
    }

    @Test("unreadable reconstruction and active owners survive cache pressure")
    func uncertainReconstructionDoesNotDiscardOwners() {
        let store = ConversationSessionStore(warmLimit: 0)
        let unknown = ConversationSession(conversationID: "unknown", configuration: nil)
        store.retain(unknown, reconstruction: .unavailable)
        let running = ConversationSession(conversationID: "running", configuration: nil)
        store.retain(running, reconstruction: .history(configuration: nil))
        store.activate(ConversationSession(conversationID: "current", configuration: nil))
        store.evictIfNeeded(isRuntimeProtected: { $0 == "running" })
        #expect(store.session(for: "unknown") === unknown)
        #expect(store.session(for: "running") === running)
        store.evictIfNeeded(isRuntimeProtected: { _ in false })
        #expect(store.session(for: "running") == nil)
        #expect(store.session(for: "unknown") === unknown)
    }
}
