import UIKit

/// Mirrors a layout guide's solved frame into a hidden UIView so geometry
/// changes remain observable even when the guide owner itself does not resize.
@MainActor
final class ComposerKeyboardAnchorObserver {
    private let probe: GeometryProbeView
    private var constraints: [NSLayoutConstraint]
    private var isInvalidated = false

    init(guide: UILayoutGuide, onChange: @escaping () -> Void) {
        guard let owner = guide.owningView else {
            preconditionFailure("A keyboard anchor must be installed in a view before observing it.")
        }

        let probe = GeometryProbeView(onGeometryChange: onChange)
        self.probe = probe
        self.constraints = []
        probe.translatesAutoresizingMaskIntoConstraints = false
        probe.isHidden = true
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = false
        probe.accessibilityElementsHidden = true
        owner.addSubview(probe)

        let constraints = [
            probe.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            probe.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            probe.topAnchor.constraint(equalTo: guide.topAnchor),
            probe.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ]
        self.constraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    /// Stops callbacks from this guide before its owner or the observed guide changes.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        probe.stopObserving()
        NSLayoutConstraint.deactivate(constraints)
        constraints.removeAll()
        probe.removeFromSuperview()
    }
}

@MainActor
private final class GeometryProbeView: UIView {
    private struct Geometry: Equatable {
        let frame: CGRect
        let bounds: CGRect
    }

    private var lastGeometry: Geometry?
    private var onGeometryChange: (() -> Void)?

    init(onGeometryChange: @escaping () -> Void) {
        self.onGeometryChange = onGeometryChange
        super.init(frame: .zero)
        lastGeometry = currentGeometry
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var frame: CGRect {
        didSet { reportGeometryChangeIfNeeded() }
    }

    override var bounds: CGRect {
        didSet { reportGeometryChangeIfNeeded() }
    }

    override var center: CGPoint {
        didSet { reportGeometryChangeIfNeeded() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportGeometryChangeIfNeeded()
    }

    func stopObserving() {
        onGeometryChange = nil
        lastGeometry = nil
    }

    private var currentGeometry: Geometry {
        Geometry(frame: frame, bounds: bounds)
    }

    private func reportGeometryChangeIfNeeded() {
        guard let onGeometryChange else { return }
        let geometry = currentGeometry
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        onGeometryChange()
    }
}