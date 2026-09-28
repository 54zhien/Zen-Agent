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
        case history(configuration: ConversationComposerConfiguration?)
    }

    private struct Entry {
        let session: ConversationSession
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

    func state(for conversationID: String) -> ConversationSessionState {
        entries[conversationID]?.state ?? .evicted
    }

    func retain(_ session: ConversationSession, reconstruction: Reconstruction) {
        let id = session.conversationID
        if var entry = entries[id], entry.session === session {
            entry.reconstruction = reconstruction
            entries[id] = entry
        } else {
            accessOrder += 1
            let date = now()
            entries[id] = Entry(session: session, reconstruction: reconstruction,
                lastAccess: date, accessOrder: accessOrder,
                state: activeID == id ? .active : .warm(lastAccess: date))
        }
    }

    /// Called only after the replacement Pane has loaded and registered.
    func activate(_ session: ConversationSession) {
        if let activeID, var previous = entries[activeID] {
            previous.state = .warm(lastAccess: previous.lastAccess)
            entries[activeID] = previous
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
