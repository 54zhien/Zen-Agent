import UIKit

/// The action panel scales as one surface. A system UIMenu owns its glass
/// deformation, so changing only its source preview cannot remove the bubble.
@MainActor
final class ComposerActionsMenuView: UIView {
    private let sourceView: UIView
    private let onModel: () -> Void
    private let outside = UIControl()
    private let panel = UIView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let scroll = UIScrollView()
    private let rows = UIStackView()

    init(sourceView: UIView, onModel: @escaping () -> Void) {
        self.sourceView = sourceView
        self.onModel = onModel
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessibilityViewIsModal = true
        keyboardLayoutGuide.followsUndockedKeyboard = true
        outside.frame = bounds
        outside.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outside.addTarget(self, action: #selector(close), for: .touchUpInside)
        addSubview(outside)

        addSubview(panel)
        glass.cornerConfiguration = .corners(radius: .fixed(28))
        glass.isUserInteractionEnabled = false
        glass.accessibilityElementsHidden = true
        panel.addSubview(glass)
        // Material is decorative; the rows keep an ordinary UIKit input/AX path.
        panel.addSubview(scroll)
        scroll.accessibilityIdentifier = "composer-actions-list"
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        for (title, symbol) in [("推理强度", "slider.horizontal.3"), ("模型", "cpu"),
                                ("插件", "puzzlepiece"), ("添加文件", "doc"),
                                ("添加图片", "photo")] {
            let button = UIButton(type: .system)
            var style = UIButton.Configuration.plain()
            style.title = title
            style.image = UIImage(systemName: symbol)
            style.imagePadding = 12
            style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                font: .preferredFont(forTextStyle: .body)
            )
            style.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            style.baseForegroundColor = .label
            style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = UIFont.preferredFont(forTextStyle: .body)
                return result
            }
            button.configuration = style
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.isEnabled = title == "模型"
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addTarget(self, action: #selector(selectModel), for: .touchUpInside)
            rows.addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = safeAreaInsets
        var safe = bounds.inset(by: insets).insetBy(dx: 12, dy: 8)
        let source = convert(sourceView.bounds, from: sourceView)
        let width = min(safe.width, UIFontMetrics(forTextStyle: .body).scaledValue(for: 250))
        let x = min(max(safe.minX, source.minX), safe.maxX - width)
        let keyboard = keyboardLayoutGuide.layoutFrame
        // A floating keyboard only limits the panel when their horizontal
        // ranges overlap. Keep the available region on the source's side.
        if keyboard.intersects(CGRect(x: x, y: safe.minY, width: width, height: safe.height)) {
            if source.midY >= keyboard.maxY {
                let bottom = safe.maxY
                safe.origin.y = max(safe.minY, keyboard.maxY + 8)
                safe.size.height = max(0, bottom - safe.minY)
            } else {
                safe.size.height = max(0, min(safe.maxY, keyboard.minY - 8) - safe.minY)
            }
        }
        scroll.bounds.size.width = width
        let fitted = rows.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        let above = max(0, min(source.maxY, safe.maxY) - safe.minY)
        let below = max(0, safe.maxY - max(safe.minY, source.minY))
        let opensAbove = fitted.height + 16 <= above || above >= below
        let height = min(fitted.height + 16, max(above, below))
        let idealY = opensAbove ? source.maxY - height : source.minY
        let y = min(max(safe.minY, idealY), safe.maxY - height)
        // Frame is undefined while the panel has a scale transform.
        panel.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        panel.center = CGPoint(x: x + width / 2, y: y + height / 2)
        glass.frame = panel.bounds
        scroll.frame = CGRect(x: 0, y: min(8, height / 2), width: width, height: max(0, height - 16))
    }

    private var collapsedTransform: CGAffineTransform {
        guard !UIAccessibility.isReduceMotionEnabled else { return .identity }
        let source = convert(sourceView.bounds, from: sourceView)
        let scale = min(1, source.width / panel.bounds.width)
        return CGAffineTransform(translationX: source.midX - panel.center.x,
                                 y: source.midY - panel.center.y).scaledBy(x: scale, y: scale)
    }

    @objc private func close() {
        guard panel.isUserInteractionEnabled else { return }
        animate(presenting: false)
    }

    @objc private func selectModel() {
        guard panel.isUserInteractionEnabled else { return }
        WorkspaceHaptics.shared.play(.control)
        animate(presenting: false, completion: onModel)
    }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    func show(in window: UIWindow) {
        // A menu is not a new input destination. Stay in the current window
        // instead of changing UIKit's modal keyboard context.
        frame = window.bounds
        window.addSubview(self)
        layoutIfNeeded()
        panel.transform = collapsedTransform
        scroll.alpha = 0
        animate(presenting: true)
    }

    private func animate(presenting: Bool, completion: (() -> Void)? = nil) {
        // The window overlay keeps absorbing touches while its controls settle.
        outside.isUserInteractionEnabled = false
        panel.isUserInteractionEnabled = false
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.12 : (presenting ? 0.28 : 0.22)
        UIView.animate(withDuration: duration, delay: 0,
                       options: presenting ? .curveEaseOut : .curveEaseIn) {
            self.panel.transform = presenting ? .identity : self.collapsedTransform
            // Glass must composite at full alpha; fade its content instead.
            self.scroll.alpha = presenting ? 1 : 0
        } completion: { _ in
            if presenting {
                self.outside.isUserInteractionEnabled = true
                self.panel.isUserInteractionEnabled = true
                if self.window != nil, self.sourceView.window === self.window {
                    let firstAction = self.rows.arrangedSubviews.first { ($0 as? UIControl)?.isEnabled == true }
                    UIAccessibility.post(notification: .layoutChanged, argument: firstAction)
                }
            } else {
                let ownerIsMounted = self.window != nil && self.sourceView.window === self.window
                self.removeFromSuperview()
                if ownerIsMounted {
                    if let completion {
                        completion()
                    } else {
                        UIAccessibility.post(notification: .layoutChanged, argument: self.sourceView)
                    }
                }
            }
        }
    }
}
