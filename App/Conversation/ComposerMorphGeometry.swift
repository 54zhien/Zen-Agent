import UIKit

/// All child coordinates are relative to the surface. The keyboard guide owns its window origin.
struct ComposerMorphGeometry {
    let size: CGSize
    let bottomSpacing: CGFloat
    let textViewport: CGRect
    let plus: CGRect
    let primary: CGRect
    let textOrigin: CGPoint
    let minimumCurvature: CGFloat

    static func endpoint(
        _ state: ComposerPresentationState,
        containerWidth: CGFloat,
        availableHeight: CGFloat,
        measuredTextHeight: CGFloat,
        lineHeight: CGFloat,
        collapseProgress: ComposerCollapseProgress
    ) -> Self {
        let layout = ComposerGeometry.resolve(
            state: state,
            containerWidth: containerWidth,
            availableHeight: availableHeight,
            measuredTextHeight: measuredTextHeight,
            scaledLineHeight: lineHeight,
            collapseProgress: collapseProgress
        )
        let origin = layout.outerFrame.origin
        func local(_ frame: CGRect?) -> CGRect {
            guard let frame else { return .zero }
            return frame.offsetBy(dx: -origin.x, dy: -origin.y)
        }
        let text = local(layout.textFrame)
        return Self(
            size: layout.outerFrame.size,
            bottomSpacing: layout.bottomSpacing,
            textViewport: text,
            plus: local(ComposerContextAction.leadingPlusFrame(layout: layout, state: state)),
            primary: local(ComposerContextAction.trailingFrame(layout: layout, state: state)),
            textOrigin: text.origin,
            minimumCurvature: ComposerShapeToken.minimumRadius(for: layout)
        )
    }

    static func interpolate(_ start: Self, _ end: Self, progress: CGFloat) -> Self {
        let p = min(1, max(0, progress))
        func value(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        func point(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: value(a.x, b.x), y: value(a.y, b.y))
        }
        func rect(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(origin: point(a.origin, b.origin), size: CGSize(
                width: value(a.width, b.width), height: value(a.height, b.height)
            ))
        }
        return Self(
            size: CGSize(width: value(start.size.width, end.size.width),
                         height: value(start.size.height, end.size.height)),
            bottomSpacing: value(start.bottomSpacing, end.bottomSpacing),
            textViewport: rect(start.textViewport, end.textViewport),
            plus: rect(start.plus, end.plus),
            primary: rect(start.primary, end.primary),
            textOrigin: point(start.textOrigin, end.textOrigin),
            minimumCurvature: value(start.minimumCurvature, end.minimumCurvature)
        )
    }
}
