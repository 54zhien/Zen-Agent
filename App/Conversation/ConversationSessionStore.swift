import Foundation

enum ConversationSessionState: Equatable {
    case active
    case warm(lastAccess: Date)
    case evicted
}

/// Presentation owners only. Runtime routes and durable history outlive eviction.
@MainActor
final class ConversationSessionStore {
    enum Reconstruction {
        case unavailable
        case uncommitted
        case history(configuration: ConversationComposerConfiguration?)
    }

    private struct Entry {
        let session: ConversationSession
        let creationOrder: UInt64
        let initialConfiguration: ConversationComposerConfiguration?
        var reconstruction: Reconstruction
        var lastAccess: Date
        var accessOrder: UInt64
        var state: ConversationSessionState
    }

    private var entries: [String: Entry] = [:]
    private var activeID: String?
    private var accessOrder: UInt64 = 0
    private let warmLimit: Int
    private let now: () -> Date

    init(warmLimit: Int = 10, now: @escaping () -> Date = Date.init) {
        self.warmLimit = max(0, warmLimit)
        self.now = now
    }

    func session(for conversationID: String) -> ConversationSession? {
        entries[conversationID]?.session
    }

    var uncommittedIDs: [String] {
        entries.filter { if case .uncommitted = $0.value.reconstruction { return true }; return false }
            .sorted { $0.value.creationOrder > $1.value.creationOrder }.map(\.key)
    }

    func uncommittedSession(for id: String) -> ConversationSession? {
        guard let entry = entries[id], case .uncommitted = entry.reconstruction else { return nil }
        return entry.session
    }

    func state(for conversationID: String) -> ConversationSessionState {
        entries[conversationID]?.state ?? .evicted
    }

    func retain(_ session: ConversationSession, reconstruction: Reconstruction) {
        let id = session.conversationID
        if var entry = entries[id], entry.session === session {
            // Read uncertainty cannot erase previously established warm-only provenance.
            if case .uncommitted = entry.reconstruction, case .unavailable = reconstruction {
                return
            }
            entry.reconstruction = reconstruction
            entries[id] = entry
        } else {
            accessOrder += 1
            let date = now()
            entries[id] = Entry(session: session,
                creationOrder: accessOrder, initialConfiguration: session.composer.configuration,
                reconstruction: reconstruction,
                lastAccess: date, accessOrder: accessOrder,
                state: activeID == id ? .active : .warm(lastAccess: date))
        }
    }

    /// Called only after the replacement Pane has loaded and registered.
    func activate(_ session: ConversationSession, isRuntimeProtected: (String) -> Bool = { _ in false }) {
        if let activeID, activeID != session.conversationID, var previous = entries[activeID] {
            // Only a pristine blank working page can be retired on replacement.
            // Drafts, changed configuration, anchors and pending submission retain their owner.
            if case .uncommitted = previous.reconstruction,
               !isRuntimeProtected(activeID),
               previous.session.canReconstruct(configuration: previous.initialConfiguration) {
                entries.removeValue(forKey: activeID)
            } else {
                previous.state = .warm(lastAccess: previous.lastAccess)
                entries[activeID] = previous
            }
        }
        let id = session.conversationID
        var entry = entries[id]
        if entry?.session !== session {
            retain(session, reconstruction: .unavailable)
            entry = entries[id]
        }
        guard var incoming = entry else { return }
        accessOrder += 1
        incoming.lastAccess = now()
        incoming.accessOrder = accessOrder
        incoming.state = .active
        entries[id] = incoming
        activeID = id
    }

    func remove(conversationID: String) {
        entries.removeValue(forKey: conversationID)
        if activeID == conversationID { activeID = nil }
    }

    func removeAll() {
        entries.removeAll()
        activeID = nil
    }

    func evictIfNeeded(isRuntimeProtected: (String) -> Bool) {
        let candidates = entries.filter { id, entry in
            guard id != activeID, !isRuntimeProtected(id),
                  case .history(let configuration) = entry.reconstruction else { return false }
            return entry.session.canReconstruct(configuration: configuration)
        }.sorted { $0.value.accessOrder < $1.value.accessOrder }
        for candidate in candidates.prefix(max(0, candidates.count - warmLimit)) {
            entries.removeValue(forKey: candidate.key)
        }
    }
}
