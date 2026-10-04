import SwiftUI
import UIKit

@MainActor
struct SplitDividerView: UIViewRepresentable {
    let ratio: Double
    let closeIntent: SplitDropSlot?
    let canCloseTop: Bool
    let canCloseBottom: Bool
    let onBegin: () -> Bool
    let onMove: (Double) -> Void
    let onEnd: (Bool) -> Void
    let onClose: (SplitDropSlot) -> Void
    let onAdjust: (Bool) -> Void
    var axis: SplitWorkspaceAxis = .topBottom
    var onAxis: ((SplitWorkspaceAxis) -> Void)? = nil
    var resizeDiagnostic: (() -> String)? = nil

    func makeUIView(context: Context) -> SplitDividerHandle {
        let view = SplitDividerHandle()
        view.configuration = self
        return view
    }

    func updateUIView(_ view: SplitDividerHandle, context: Context) { view.configuration = self }

    static func dismantleUIView(_ view: SplitDividerHandle, coordinator: ()) {
        view.cancelPan()
    }
}

@MainActor
final class SplitDividerHandle: UIView, UIContextMenuInteractionDelegate {
    var configuration: SplitDividerView? {
        didSet {
            accessibilityValue = configuration.map {
                $0.axis == .topBottom ? "上方 \(Int($0.ratio * 100))%，下方 \(Int((1 - $0.ratio) * 100))%"
                    : "左侧 \(Int($0.ratio * 100))%，右侧 \(Int((1 - $0.ratio) * 100))%"
            }
            var actions: [UIAccessibilityCustomAction] = []
            if configuration?.canCloseTop == true {
                actions.append(UIAccessibilityCustomAction(name: configuration?.axis == .leftRight ? "关闭左侧窗格" : "关闭上方窗格", target: self, selector: #selector(closeTop)))
            }
            if configuration?.canCloseBottom == true {
                actions.append(UIAccessibilityCustomAction(name: configuration?.axis == .leftRight ? "关闭右侧窗格" : "关闭下方窗格", target: self, selector: #selector(closeBottom)))
            }
            if configuration?.onAxis != nil {
                actions.append(UIAccessibilityCustomAction(name: "上下分屏", target: self, selector: #selector(verticalAxis)))
                actions.append(UIAccessibilityCustomAction(name: "左右分屏", target: self, selector: #selector(horizontalAxis)))
            }
            accessibilityCustomActions = actions
#if DEBUG
            if ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1" {
                accessibilityValue = (super.accessibilityValue ?? "") + ";pan=\(pan.state.rawValue);admitted=\(panAdmitted);last=\(lastPanDiagnostic);resize=\(configuration?.resizeDiagnostic?() ?? "none")"
            }
#endif
            if oldValue?.closeIntent != configuration?.closeIntent, configuration?.closeIntent != nil {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            handle.backgroundColor = configuration?.closeIntent == nil ? .white : .systemOrange
            setNeedsLayout()
        }
    }
    private let handle = UIView()
    private var panAdmitted = false
#if DEBUG
    private var lastPanDiagnostic = "none"
    private var lastBeginAdmitted = false
    private var menuVisible = false
    private var menuGeneration: UInt64 = 0
    private var touchDiagnostic = "none"

    private func recordTouch(_ phase: String, _ touches: Set<UITouch>) {
        guard ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1",
              let touch = touches.first else { return }
        let point = touch.location(in: window)
        let hit = window?.hitTest(point, with: nil)
        touchDiagnostic = "\(phase),point=\(point),hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        recordTouch("began", touches)
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        recordTouch("ended", touches)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        recordTouch("cancelled", touches)
        super.touchesCancelled(touches, with: event)
    }

    override var accessibilityValue: String? {
        get {
            guard ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1" else {
                return super.accessibilityValue
            }
            let point = CGPoint(x: bounds.midX, y: bounds.midY)
            let hit = window?.hitTest(convert(point, to: window), with: nil)
            let ownsHit = hit === self || hit?.isDescendant(of: self) == true
            let ready = window != nil && !menuVisible && ownsHit
            return (super.accessibilityValue ?? "")
                + ";dividerReady=\(ready);menuVisible=\(menuVisible);centerHit=\(hit.map { String(describing: type(of: $0)) } ?? "nil");handleIdentity=\(ObjectIdentifier(self));panEnabled=\(pan.isEnabled);touch=\(touchDiagnostic);liveResize=\(configuration?.resizeDiagnostic?() ?? "none")"
        }
        set { super.accessibilityValue = newValue }
    }
#endif
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned))

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(handle)
        handle.isUserInteractionEnabled = false
        handle.backgroundColor = .white
        handle.layer.cornerRadius = 2
        addGestureRecognizer(pan)
        addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        accessibilityLabel = "分屏分隔线"
        accessibilityHint = "拖动调整比例，长按选择关闭窗格"
        accessibilityIdentifier = "split-divider-handle"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        handle.frame = configuration?.axis == .leftRight
            ? CGRect(x: (bounds.width - 4) / 2, y: 0, width: 4, height: bounds.height)
            : CGRect(x: 0, y: (bounds.height - 4) / 2, width: bounds.width, height: 4)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let configuration else { return }
        switch recognizer.state {
        case .began:
            panAdmitted = configuration.onBegin()
#if DEBUG
            lastBeginAdmitted = panAdmitted
#endif
            if panAdmitted { configuration.onMove(displacement(recognizer)) }
        case .changed:
            if panAdmitted { configuration.onMove(displacement(recognizer)) }
        case .ended:
            if panAdmitted {
                configuration.onMove(displacement(recognizer))
                panAdmitted = false
                configuration.onEnd(false)
            }
        case .cancelled, .failed:
            cancelPan()
        default: break
        }
#if DEBUG
        lastPanDiagnostic = "state=\(recognizer.state.rawValue),begin=\(lastBeginAdmitted),admitted=\(panAdmitted),translation=\(displacement(recognizer))"
        if ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1" {
            accessibilityValue = "ratio=\(configuration.ratio);axis=\(configuration.axis);\(lastPanDiagnostic);resize=\(configuration.resizeDiagnostic?() ?? "none")"
        }
#endif
    }

    private func displacement(_ pan: UIPanGestureRecognizer) -> Double {
        let value = pan.translation(in: window)
        return Double(configuration?.axis == .leftRight ? value.x : value.y)
    }
    @objc private func verticalAxis() -> Bool { configuration?.onAxis?(.topBottom); return configuration?.onAxis != nil }
    @objc private func horizontalAxis() -> Bool { configuration?.onAxis?(.leftRight); return configuration?.onAxis != nil }

    func cancelPan() {
        guard panAdmitted else { return }
        panAdmitted = false
        configuration?.onEnd(true)
    }

    override func accessibilityIncrement() { configuration?.onAdjust(true) }
    override func accessibilityDecrement() { configuration?.onAdjust(false) }

    @objc private func closeTop() -> Bool {
        guard configuration?.canCloseTop == true else { return false }
        configuration?.onClose(.top)
        return true
    }
    @objc private func closeBottom() -> Bool {
        guard configuration?.canCloseBottom == true else { return false }
        configuration?.onClose(.bottom)
        return true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu(children: []) }
            var actions: [UIMenuElement] = [
                UIAction(title: self.configuration?.axis == .leftRight ? "关闭左侧窗格" : "关闭上方窗格", attributes: self.configuration?.canCloseTop == true ? [] : [.disabled]) { [weak self] _ in _ = self?.closeTop() },
                UIAction(title: self.configuration?.axis == .leftRight ? "关闭右侧窗格" : "关闭下方窗格", attributes: self.configuration?.canCloseBottom == true ? [] : [.disabled]) { [weak self] _ in _ = self?.closeBottom() }
            ]
            if self.configuration?.onAxis != nil {
                actions += [UIAction(title: "上下分屏", state: self.configuration?.axis == .topBottom ? .on : .off) { [weak self] _ in _ = self?.verticalAxis() },
                            UIAction(title: "左右分屏", state: self.configuration?.axis == .leftRight ? .on : .off) { [weak self] _ in _ = self?.horizontalAxis() }]
            }
            return UIMenu(children: actions)
        }
    }

#if DEBUG
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        menuGeneration &+= 1
        menuVisible = true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        let generation = menuGeneration
        // The action can change axis before UIKit removes the menu's hit layer.
        // Tests observe the real completion and hit target instead of sleeping.
        let finished = { [weak self] in
            guard let self, self.menuGeneration == generation else { return }
            self.menuVisible = false
        }
        if let animator { animator.addCompletion(finished) } else { finished() }
    }
#endif
}
