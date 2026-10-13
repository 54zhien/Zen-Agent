/// A position measured from one Turn/viewport snapshot, scoped to its attachment.
/// Native dimension callbacks that repeat an older offset do not revoke it.
struct ConversationMaterializedScrollObservation: Equatable, Sendable {
    let runID: String
    let layoutRevision: UInt64
    let workspaceRevision: UInt64
    let nativeOffset: Double
    let contentTop: Double
    let geometry: ScrollGeometry

    func isWithinUnclampedBounds(_ native: ScrollGeometry, anchor: TurnAnchor) -> Bool {
        guard native.isUsableForPane, geometry.isUsableForPane,
              let target = AnchorResolver.restoreTarget(anchor: anchor, turnTop: contentTop,
                                                        geometry: native) else { return false }
        let maximum = max(0, native.contentHeight - native.viewportHeight)
        // A Turn proves position, not current bounds. Clamp-dependent restoration
        // retains its native receipt instead of borrowing this observation.
        return target > 0 && target < maximum && geometry.offset >= 0 && geometry.offset <= maximum
    }

    func mergingMetadata(from native: ScrollGeometry, previousNativeOffset: Double,
                         anchor: TurnAnchor, layoutRevision: UInt64,
                         workspaceRevision: UInt64) -> ScrollGeometry? {
        guard anchor.runID == runID, self.layoutRevision == layoutRevision,
              self.workspaceRevision == workspaceRevision,
              previousNativeOffset == native.offset, nativeOffset == native.offset,
              abs(geometry.viewportHeight - native.viewportHeight) <= 0.5,
              isWithinUnclampedBounds(native, anchor: anchor) else { return nil }
        return ScrollGeometry(viewportHeight: native.viewportHeight,
                              contentHeight: native.contentHeight, offset: geometry.offset)
    }
}
