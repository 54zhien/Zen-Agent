import Foundation

struct FileWorkspaceCursor: Equatable, Sendable {
    let updatedAt: Date
    let id: String
}

/// Metadata only. Byte availability is verified when opening a native presentation.
struct FileWorkspaceItem: Identifiable, Equatable, Sendable {
    let id: String
    let versionID: String
    let displayName: String
    let byteCount: Int64?
    let mediaType: String?
    let fingerprint: String?
    let origin: FileAssetOrigin?
    let cursor: FileWorkspaceCursor

    var attachment: SendAttachment? {
        guard let fingerprint, byteCount != nil else { return nil }
        return SendAttachment(assetID: id, versionID: versionID, fingerprint: fingerprint,
                              kind: .file, displayName: displayName)
    }
}

struct FileWorkspacePage: Equatable, Sendable {
    let items: [FileWorkspaceItem]
    let nextCursor: FileWorkspaceCursor?
}
