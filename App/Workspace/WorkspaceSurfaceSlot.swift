/// Fixed native host identities, independent of which host currently owns Single.
enum WorkspaceSurfaceSlot: CaseIterable, Hashable {
    case primary, secondary
    var other: Self { self == .primary ? .secondary : .primary }
}
