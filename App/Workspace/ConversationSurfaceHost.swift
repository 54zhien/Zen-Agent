import SwiftUI
import UIKit

@MainActor
struct ConversationSurfaceHost<Content: View>: UIViewControllerRepresentable {
    var request: SurfaceGeometry.Request = .full
    let content: Content

    init(request: SurfaceGeometry.Request = .full, @ViewBuilder content: () -> Content) {
        self.request = request
        self.content = content()
    }

    func makeUIViewController(context: Context) -> ConversationSurfaceViewController<Content> {
        ConversationSurfaceViewController(content: content, request: request)
    }

    func updateUIViewController(_ controller: ConversationSurfaceViewController<Content>, context: Context) {
        // Content is installed once. Its own observed state drives updates; progress
        // must not replace the hosting root or invalidate the Timeline each frame.
        _ = controller.apply(request)
    }
}

@MainActor
final class ConversationSurfaceViewController<Content: View>: UIViewController {
    let contentController: UIHostingController<Content>
    let surfaceView = UIView()
    private(set) var presentation = SurfaceGeometry.Presentation.full
    private var request = SurfaceGeometry.Request.full

    init(content: Content, request: SurfaceGeometry.Request = .full) {
        contentController = UIHostingController(rootView: content)
        if request.isValid { self.request = request }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(content:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        surfaceView.layer.cornerCurve = .continuous
        surfaceView.clipsToBounds = true
        view.addSubview(surfaceView)
        addChild(contentController)
        let contentView = contentController.view!
        contentView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: surfaceView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor)
        ])
        contentController.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Bounds and center remain independent of the presentation transform.
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if surfaceView.bounds != bounds { surfaceView.bounds = bounds }
        if surfaceView.center != center { surfaceView.center = center }
        _ = apply(request)
    }

    @discardableResult
    func apply(_ candidate: SurfaceGeometry.Request) -> Bool {
        guard let resolved = SurfaceGeometry.resolve(size: view.bounds.size, safeArea: view.safeAreaInsets, request: candidate) else { return false }
        request = candidate
        guard presentation != resolved else { return true }
        presentation = resolved
        surfaceView.transform = CGAffineTransform(a: resolved.scale, b: 0, c: 0, d: resolved.scale, tx: resolved.translation.width, ty: resolved.translation.height)
        surfaceView.layer.cornerRadius = resolved.cornerRadius
        return true
    }

    override var childForStatusBarStyle: UIViewController? { contentController }
    override var childForStatusBarHidden: UIViewController? { contentController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { contentController }
}
