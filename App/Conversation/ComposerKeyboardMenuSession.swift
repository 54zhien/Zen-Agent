import UIKit
import OSLog

/// One owner for the sequential handoff and the occupied input region. Native
/// focus can end without changing the Composer's logical Editing presentation.
@MainActor
final class ComposerKeyboardMenuSession: NSObject {
    private enum Phase { case preparing, hidingKeyboard, showingMenu, menu, hidingMenu, restoringKeyboard, finished }
    private let logger = Logger(subsystem: "com.zhien.zen", category: "ComposerInputHandoff")
    private var phase = Phase.preparing {
        didSet { logger.debug("phase=\(String(describing: self.phase), privacy: .public)") }
    }
    private var isSuspended = false
    private var receivedWillHide = false
    private weak var editor: UITextView?
    private weak var window: UIWindow?
    private let windowSize: CGSize
    private let presenter: ComposerKeyboardMenuPresenter
    private let onReservation: (CGFloat?) -> Void
    private let onGlyph: (Bool, Bool) -> Void
    private let onFinish: (ComposerKeyboardMenuSession) -> Void
    private var returnsToKeyboard = false
    private var endingInput = false
    private var watchdog: Task<Void, Never>?
    private(set) var reservedTop: CGFloat?
    var permitsNativeFocus: Bool { !isSuspended && phase == .restoringKeyboard }

    init(editor: UITextView, window: UIWindow, height: CGFloat,
         presenter: ComposerKeyboardMenuPresenter,
         onReservation: @escaping (CGFloat?) -> Void,
         onGlyph: @escaping (Bool, Bool) -> Void,
         onFinish: @escaping (ComposerKeyboardMenuSession) -> Void) {
        self.editor = editor
        self.window = window
        windowSize = window.bounds.size
        self.presenter = presenter
        reservedTop = window.bounds.maxY - height
        self.onReservation = onReservation
        self.onGlyph = onGlyph
        self.onFinish = onFinish
        super.init()
        presenter.onClose = { [weak self] restore, animated in
            self?.close(restoringKeyboard: restore, animated: animated)
        }
        presenter.onInvalidated = { [weak self] in self?.close(restoringKeyboard: false, animated: false) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide(_:)),
                           name: UIResponder.keyboardDidHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidShow(_:)),
                           name: UIResponder.keyboardDidShowNotification, object: nil)
        center.addObserver(self, selector: #selector(deactivate),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(activate),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start() {
        onReservation(reservedTop)
        onGlyph(true, true)
        // Let the published reservation reach the Workspace before asking UIKit
        // to change its safe area. This is scheduling, not an animation timer.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.phase == .preparing else { return }
            guard self.isAttached, let editor = self.editor else { self.finish(resign: true); return }
            if self.returnsToKeyboard { self.finish(resign: false); return }
            self.window?.layoutIfNeeded()
            self.phase = .hidingKeyboard
            self.armWatchdog()
            let accepted = editor.resignFirstResponder()
            self.logger.debug("resign accepted=\(accepted) focused=\(editor.isFirstResponder)")
            if !accepted, editor.isFirstResponder { self.finish(resign: false) }
        }
    }

    func close(restoringKeyboard: Bool = true, animated: Bool = true) {
        guard phase != .finished else { return }
        logger.debug("close restore=\(restoringKeyboard) phase=\(String(describing: self.phase), privacy: .public)")
        guard !isSuspended else { finish(resign: true); return }
        if !restoringKeyboard {
            let alreadyEnding = endingInput
            endingInput = true
            returnsToKeyboard = false
            watchdog?.cancel()
            guard animated else { finish(resign: true); return }
            guard !alreadyEnding else { return }
            onGlyph(false, true)
            switch phase {
            case .showingMenu, .menu:
                phase = .hidingMenu
                presenter.dismiss(animated: true) { [weak self] in self?.finish(resign: true) }
            case .hidingMenu:
                // The existing close animation will observe the new destination.
                break
            case .preparing, .hidingKeyboard, .restoringKeyboard, .finished:
                finish(resign: true)
            }
            return
        }
        guard !endingInput else { return }
        returnsToKeyboard = true
        onGlyph(false, animated)
        switch phase {
        case .preparing, .hidingKeyboard:
            // A second tap during keyboard descent changes the destination,
            // but must not reverse/restart the native keyboard mid-dismissal.
            break
        case .showingMenu, .menu:
            phase = .hidingMenu
            presenter.dismiss(animated: animated) { [weak self] in
                guard let self else { return }
                if self.endingInput { self.finish(resign: true) }
                else { self.restoreKeyboard() }
            }
        case .hidingMenu, .restoringKeyboard, .finished:
            break
        }
    }

    func nativeEditingEnded() {
        // Losing focus during our initial descent is expected. Losing it after
        // restoration began means another responder now owns input; do not
        // keep its viewport reserved until a timeout or steal focus back.
        if phase == .restoringKeyboard { finish(resign: false) }
    }

    func validateAttachment() {
        guard phase != .finished else { return }
        if !isAttached { finish(resign: true) }
    }

    private var isAttached: Bool {
        guard let window, editor?.window === window, window.bounds.size == windowSize else { return false }
        return true
    }

    private func belongsToWindow(_ notification: Notification) -> Bool {
        guard !isSuspended, isAttached, let window,
              window.windowScene.map({ $0.activationState == .foregroundActive }) ?? true else { return false }
        if let screen = notification.object as? UIScreen, screen !== window.screen { return false }
        if let local = notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? NSNumber,
           !local.boolValue { return false }
        return true
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard phase == .hidingKeyboard, belongsToWindow(notification) else { return }
        receivedWillHide = true
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        guard phase == .hidingKeyboard, receivedWillHide, belongsToWindow(notification) else { return }
        // didHide is the completion signal. A third-party input extension's
        // frame payload is not a second visibility contract. Defer one main
        // actor turn so the responder's resignation callbacks finish first.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.completeKeyboardDescent()
        }
    }

    private func completeKeyboardDescent() {
        guard !isSuspended, phase == .hidingKeyboard, isAttached,
              editor?.isFirstResponder == false, let window else { return }
        if let owner = inputOwner(in: window), owner !== editor { finish(resign: false); return }
        watchdog?.cancel()
        if returnsToKeyboard { restoreKeyboard(); return }
        phase = .showingMenu
        presenter.reveal(in: window) { [weak self] in
            guard let self, self.phase == .showingMenu else { return }
            self.phase = .menu
        }
    }

    private func restoreKeyboard() {
        guard !isSuspended, phase != .finished, isAttached, let editor else { finish(resign: true); return }
        phase = .restoringKeyboard
        armWatchdog()
        guard editor.becomeFirstResponder() else { finish(resign: false); return }
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard belongsToWindow(notification) else { return }
        if phase == .hidingKeyboard, let window,
           let owner = inputOwner(in: window), owner !== editor {
            finish(resign: false)
            return
        }
        if phase == .restoringKeyboard {
            guard let window, let info = notification.userInfo,
                  let frame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let local = window.convert(frame, from: window.screen.coordinateSpace)
            let overlap = window.bounds.intersection(local)
            if !overlap.isNull, overlap.height > window.safeAreaInsets.bottom + 1,
               abs((reservedTop ?? overlap.minY) - overlap.minY) > 0.5 {
                // Candidate bars can change the returning keyboard's height.
                // Move both consumers toward that measured endpoint during the
                // real keyboard animation, instead of jumping at didShow.
                reservedTop = overlap.minY
                let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
                let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
                UIView.animate(withDuration: duration, delay: 0,
                    options: UIView.AnimationOptions(rawValue: curve << 16).union([.beginFromCurrentState])) {
                    self.onReservation(self.reservedTop)
                }
            }
        } else if phase == .showingMenu || phase == .menu {
            // An external responder took over; it owns the next input region.
            finish(resign: false)
        }
    }

    @objc private func keyboardDidShow(_ notification: Notification) {
        if phase == .hidingKeyboard, belongsToWindow(notification), let window,
           let owner = inputOwner(in: window), owner !== editor {
            finish(resign: false)
            return
        }
        guard phase == .restoringKeyboard, belongsToWindow(notification),
              editor?.isFirstResponder == true else { return }
        window?.layoutIfNeeded()
        // The native guide now owns the occupied region again. No zero-height
        // interval is published between the panel and this completed keyboard.
        finish(resign: false)
    }

    private func inputOwner(in view: UIView) -> UIView? {
        // Only our application window, never the remote keyboard hierarchy.
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let owner = inputOwner(in: child) { return owner }
        }
        return nil
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self,
                  self.phase == .hidingKeyboard || self.phase == .restoringKeyboard else { return }
            // Missing/declined keyboard completion is cancellation, never proof
            // of dismissal. Also releases reservations for hardware keyboards.
            self.logger.error("handoff timed out in \(String(describing: self.phase), privacy: .public)")
            self.finish(resign: false)
        }
    }

    @objc private func deactivate() {
        guard phase != .finished, !isSuspended else { return }
        // A user-initiated close remains a close. An open menu keeps its
        // same-window reservation and level; never restore focus in background.
        guard !returnsToKeyboard, phase != .hidingMenu, phase != .restoringKeyboard,
              isAttached, let window else { finish(resign: true); return }
        isSuspended = true
        watchdog?.cancel()
        if phase == .preparing || phase == .hidingKeyboard {
            editor?.resignFirstResponder()
            guard editor?.isFirstResponder == false else { finish(resign: false); return }
            phase = .showingMenu
            presenter.reveal(in: window, animated: false) { [weak self] in self?.phase = .menu }
        }
        presenter.suspend()
    }

    @objc private func activate() {
        guard isSuspended, phase != .finished else { return }
        guard isAttached, let window else { finish(resign: true); return }
        if let owner = inputOwner(in: window), owner !== editor { finish(resign: false); return }
        isSuspended = false
        presenter.resume()
        onReservation(reservedTop)
        onGlyph(true, false)
    }

    private func finish(resign: Bool) {
        guard phase != .finished else { return }
        phase = .finished
        watchdog?.cancel()
        watchdog = nil
        presenter.removeFromWindow()
        if resign { editor?.resignFirstResponder() }
        reservedTop = nil
        onReservation(nil)
        onGlyph(false, false)
        onFinish(self)
    }
}
