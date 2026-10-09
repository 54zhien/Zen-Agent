import UIKit
import SwiftUI

/// UIKit owns the vertical pan and pixels. The App Shell owns Stop, persistence,
/// and Undo; no gesture callback edits Conversation lifecycle directly.
@MainActor
final class AppSpaceCardDeletionInteraction: NSObject, UIGestureRecognizerDelegate {
    typealias Commit = @MainActor (String, @MainActor () -> Bool) async -> Bool

    let recognizer = UIPanGestureRecognizer()
    private weak var surface: SurfaceClipView?
    private weak var coordinates: UIView?
    private let browse: AppSpaceBrowseController
    private let canDelete: @MainActor () -> Bool
    private let refreshAccessibility: @MainActor () -> Void
    private var commit: Commit
    private var stillPending: @MainActor (String) -> Bool

    private var capturedID: String?
    private var identity: UUID?
    private var baseTransform = CGAffineTransform.identity
    private var cardHeight: Double = 0
    private var hapticSent = false
    private var animator: UIViewPropertyAnimator?
    private var deleteTask: Task<Void, Never>?

    init(surface: SurfaceClipView, coordinates: UIView, browse: AppSpaceBrowseController,
         canDelete: @escaping @MainActor () -> Bool,
         refreshAccessibility: @escaping @MainActor () -> Void,
         stillPending: @escaping @MainActor (String) -> Bool,
         commit: @escaping Commit) {
        self.surface = surface
        self.coordinates = coordinates
        self.browse = browse
        self.canDelete = canDelete
        self.refreshAccessibility = refreshAccessibility
        self.stillPending = stillPending
        self.commit = commit
        super.init()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(gestureChanged(_:)))
        surface.addGestureRecognizer(recognizer)
    }

    func updateActions(commit: @escaping Commit,
                       stillPending: @escaping @MainActor (String) -> Bool) {
        self.commit = commit
        self.stillPending = stillPending
    }

    var canTrigger: Bool {
        capturedID == nil && deleteTask == nil && browse.currentSummary != nil && canDelete()
    }

    func updateAvailability() {
        let enabled = capturedID != nil || (browse.isPresented && canDelete())
        if recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === recognizer, canTrigger, let coordinates else { return false }
        return AppSpaceCardDeletionGesture.shouldBegin(
            velocity: recognizer.velocity(in: coordinates.window ?? coordinates))
    }

    @discardableResult
    func triggerAccessibilityDelete() -> Bool {
        guard canTrigger, let id = browse.selectedConversationID, begin(id: id) else { return false }
        performDelete(id: id)
        return true
    }

    @objc private func gestureChanged(_ pan: UIPanGestureRecognizer) {
        guard let coordinates else { cancel(); return }
        let reference = coordinates.window ?? coordinates
        switch pan.state {
        case .began:
            guard canTrigger, let id = browse.selectedConversationID, begin(id: id) else { return }
            updateDrag(pan.translation(in: reference), velocity: pan.velocity(in: reference))
        case .changed:
            updateDrag(pan.translation(in: reference), velocity: pan.velocity(in: reference))
        case .ended:
            let translation = pan.translation(in: reference)
            let velocity = pan.velocity(in: reference)
            guard let id = capturedID,
                  AppSpaceCardDeletionGesture.shouldDelete(
                    translation: translation, velocity: velocity, height: cardHeight) else {
                rebound()
                return
            }
            if !hapticSent { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            performDelete(id: id)
        case .cancelled, .failed: rebound()
        default: break
        }
    }

    private func begin(id: String) -> Bool {
        guard let surface,
              let card = browse.layout()?.cards.first(where: { $0.item == browse.state.selected }) else { return false }
        animator?.stopAnimation(true)
        animator = nil
        capturedID = id
        identity = UUID()
        cardHeight = Double(card.frame.height)
        hapticSent = false
        browse.setInteractionSuspended(true)
        baseTransform = surface.transform
        refreshAccessibility()
        return true
    }

    private func updateDrag(_ translation: CGPoint, velocity: CGPoint) {
        guard capturedID != nil, cardHeight > 0 else { return }
        let offset = max(-CGFloat(cardHeight) * 1.2, min(0, translation.y))
        render(offset: offset, alpha: max(0.55, 1 + offset / CGFloat(cardHeight) * 0.4))
        if !hapticSent, AppSpaceCardDeletionGesture.shouldDelete(
            translation: translation, velocity: velocity, height: cardHeight) {
            hapticSent = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func performDelete(id: String) {
        guard let token = identity, deleteTask == nil else { return }
        let commit = self.commit
        deleteTask = Task { [weak self] in
            guard let self else { return }
            let deleted = await commit(id) { [weak self] in
                guard let self else { return false }
                return self.identity == token && self.browse.selectedConversationID == id
                    && UIApplication.shared.applicationState == .active
            }
            guard self.identity == token else { return }
            self.deleteTask = nil
            if deleted { self.slideOut(id: id, token: token) }
            else { self.rebound() }
        }
    }

    private func slideOut(id: String, token: UUID) {
        guard identity == token else { return }
        browse.beginDeletionReplacement(id: id)
        if UIAccessibility.isReduceMotionEnabled {
            browse.advanceDeletionReplacement()
            completeDelete(id: id, token: token)
            return
        }
        withAnimation(.easeInOut(duration: 0.24)) { browse.advanceDeletionReplacement() }
        let animation = UIViewPropertyAnimator(duration: 0.24, curve: .easeIn) { [weak self] in
            guard let self else { return }
            self.render(offset: -CGFloat(self.cardHeight) * 1.2, alpha: 0)
        }
        animator = animation
        animation.addCompletion { [weak self] _ in
            guard let self, self.identity == token else { return }
            self.animator = nil
            if self.stillPending(id) { self.completeDelete(id: id, token: token) }
            else { self.rebound() }
        }
        animation.startAnimation()
    }

    private func completeDelete(id: String, token: UUID) {
        guard identity == token else { return }
        guard stillPending(id) else { finishRebound(); return }
        UIView.performWithoutAnimation {
            render(offset: 0, alpha: 1)
            _ = browse.selectAfterDeleting(id: id)
            browse.setInteractionSuspended(false)
        }
        capturedID = nil
        identity = nil
        refreshAccessibility()
        UIAccessibility.post(notification: .layoutChanged, argument: surface)
    }

    private func rebound() {
        guard capturedID != nil else { return }
        animator?.stopAnimation(true)
        animator = nil
        if UIAccessibility.isReduceMotionEnabled {
            finishRebound()
            return
        }
        let animation = UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) { [weak self] in
            self?.render(offset: 0, alpha: 1)
        }
        animator = animation
        animation.addCompletion { [weak self] _ in self?.finishRebound() }
        animation.startAnimation()
    }

    private func finishRebound() {
        animator = nil
        render(offset: 0, alpha: 1)
        browse.clearDeletionReplacement()
        capturedID = nil
        identity = nil
        browse.setInteractionSuspended(false)
        refreshAccessibility()
    }

    private func render(offset: CGFloat, alpha: CGFloat) {
        guard let surface else { return }
        var transform = baseTransform
        transform.ty += offset
        surface.transform = transform
        surface.alpha = alpha
    }

    func cancel() {
        deleteTask?.cancel()
        deleteTask = nil
        animator?.stopAnimation(true)
        animator = nil
        if let id = capturedID, let token = identity, stillPending(id) {
            completeDelete(id: id, token: token)
        } else if capturedID != nil {
            finishRebound()
        }
    }

    func unbind() {
        cancel()
        surface?.removeGestureRecognizer(recognizer)
    }
}
