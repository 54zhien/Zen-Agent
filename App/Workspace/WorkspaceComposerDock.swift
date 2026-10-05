import Observation
import SwiftUI
import UIKit

private struct WorkspaceComposerDockKey: EnvironmentKey {
    static let defaultValue: WorkspaceComposerDockState? = nil
}
private struct ComposerUsesWorkspaceDockKey: EnvironmentKey {
    static let defaultValue = false
}
private struct ComposerIsActivePaneKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var workspaceComposerDock: WorkspaceComposerDockState? {
        get { self[WorkspaceComposerDockKey.self] }
        set { self[WorkspaceComposerDockKey.self] = newValue }
    }
    var composerUsesWorkspaceDock: Bool {
        get { self[ComposerUsesWorkspaceDockKey.self] }
        set { self[ComposerUsesWorkspaceDockKey.self] = newValue }
    }
    var composerIsActivePane: Bool {
        get { self[ComposerIsActivePaneKey.self] }
        set { self[ComposerIsActivePaneKey.self] = newValue }
    }
}

/// A presentation destination, never a second draft or send owner. Portals own
/// the native editors; this state holds weak registrations, bounded by live Panes.
@MainActor @Observable
final class WorkspaceComposerDockState {
    var clearance: CGFloat = 62
    var windowSize: CGSize = .zero
    var isPad = false
    @ObservationIgnored private weak var container: ComposerDockContainer?
    @ObservationIgnored private var portals: [ObjectIdentifier: WeakPortal] = [:]
    @ObservationIgnored private var activeID: String?
    @ObservationIgnored private var visible = false

    private final class WeakPortal {
        weak var value: ComposerHostPortal?
        init(_ value: ComposerHostPortal) { self.value = value }
    }

    func register(_ portal: ComposerHostPortal) {
        portals[ObjectIdentifier(portal)] = WeakPortal(portal)
        refresh()
    }
    func unregister(_ portal: ComposerHostPortal) {
        portals[ObjectIdentifier(portal)] = nil
        portal.park()
    }
    func configure(container: ComposerDockContainer, activeID: String?, visible: Bool) {
        self.container = container; self.activeID = activeID; self.visible = visible
        refresh()
    }
    func measured(_ value: CGFloat, ownerID: String) {
        guard ownerID == activeID, abs(clearance - value) > 0.5 else { return }
        clearance = value
    }
    private func refresh() {
        portals = portals.filter { $0.value.value != nil }
        let live = portals.values.compactMap(\.value)
        let selected = live.first { $0.usesDock && $0.ownerID == activeID }
        // Install the incoming responder before parking the outgoing one.
        if visible, let selected, let container {
            container.install(selected)
            measured(selected.composer.measuredClearance, ownerID: selected.ownerID)
        }
        for portal in live {
            if !portal.usesDock { portal.embed() }
            else if !visible || portal !== selected { portal.park() }
        }
    }
}

@MainActor
final class ComposerHostPortal: UIView {
    let composer = ComposerHostView()
    private(set) var ownerID = ""
    private(set) var usesDock = false
    private weak var dock: WorkspaceComposerDockState?
    private weak var driver: SurfaceLiftController?
    private var requestedFocus = false
    private var inputSuppressed = false
    private var isActivePane = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        composer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(configuration: ComposerHostView.Configuration, focused: Bool, suppressed: Bool,
                ownerID: String, usesDock: Bool, dock: WorkspaceComposerDockState?, isActivePane: Bool = true) {
        self.ownerID = ownerID; self.usesDock = usesDock
        self.requestedFocus = focused; self.inputSuppressed = suppressed; self.isActivePane = isActivePane
        self.driver = configuration.liftInteraction?.driver
        self.dock = dock
        composer.configure(configuration)
        composer.setWorkspaceInputSuppressed(suppressed)
        if let dock { dock.register(self) } else { embed() }
        applyFocusIfAttached()
        composer.consumeOverlayFocusIfReady()
    }
    func applyFocusIfAttached(transferring: Bool = false) {
        guard !inputSuppressed, composer.window != nil else { return }
        if usesDock {
            guard composer.superview is ComposerDockContainer, isActivePane || transferring else { return }
        }
        composer.requestFocus(requestedFocus || transferring)
    }
    func embed() {
        clearExternalOwner()
        guard composer.superview !== self else { return }
        composer.removeFromSuperview()
        composer.frame = bounds
        addSubview(composer)
        setNeedsLayout()
        applyFocusIfAttached()
    }
    func park() {
        clearExternalOwner()
        composer.removeFromSuperview()
    }
    func registerExternalOwner() { driver?.externalComposer = composer }
    private func clearExternalOwner() {
        if driver?.externalComposer === composer { driver?.externalComposer = nil }
    }
    func unmount() { dock?.unregister(self); park() }
    override func layoutSubviews() {
        super.layoutSubviews()
        if composer.superview === self { composer.frame = bounds }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard composer.superview === self else { return nil }
        return composer.hitTest(convert(point, to: composer), with: event)
    }
}

@MainActor
final class ComposerDockContainer: UIView {
    private weak var portal: ComposerHostPortal?
    func install(_ incoming: ComposerHostPortal) {
        guard portal !== incoming || incoming.composer.superview !== self else {
            incoming.registerExternalOwner(); incoming.applyFocusIfAttached(); return
        }
        let outgoing = portal
        let transferFocus = outgoing?.composer.editor.isFirstResponder == true
        incoming.composer.removeFromSuperview()
        incoming.composer.frame = bounds
        addSubview(incoming.composer)
        portal = incoming
        incoming.registerExternalOwner()
        incoming.composer.layoutIfNeeded()
        incoming.applyFocusIfAttached(transferring: transferFocus)
        if outgoing !== incoming { outgoing?.park() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let composer = portal?.composer, composer.superview === self { composer.frame = bounds }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let composer = portal?.composer, composer.superview === self else { return nil }
        return composer.hitTest(convert(point, to: composer), with: event)
    }
}

@MainActor
struct WorkspaceComposerDock: UIViewRepresentable {
    let state: WorkspaceComposerDockState
    let activeID: String?
    let visible: Bool
    func makeUIView(context: Context) -> ComposerDockContainer { ComposerDockContainer() }
    func updateUIView(_ view: ComposerDockContainer, context: Context) {
        state.configure(container: view, activeID: activeID, visible: visible)
    }
}
