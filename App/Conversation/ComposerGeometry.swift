import SwiftUI

struct ComposerLayout {
    let outerFrame: CGRect
    let bottomSpacing: CGFloat
    let textFrame: CGRect
    let padding: EdgeInsets
    let leadingAccessoryReserve: CGFloat
    let trailingAccessoryReserve: CGFloat
    let controlRailReserve: CGFloat
    let typographyRole: TypographyRole
    let fontScale: CGFloat
    let previewLineLimit: Int
    let textAreaIsScrollable: Bool
    let visualFrame: CGRect
    let hitFrame: CGRect

    var outerWidth: CGFloat { outerFrame.width }
    var outerHeight: CGFloat { outerFrame.height }
}

enum ComposerGeometry {
    static let edgeInset: CGFloat = 16
    // Expand equally toward the screen edges and keyboard to keep the lower corner centers fixed.
    static let restingGrowth: CGFloat = 12
    private static let restingBaseEdgeInset: CGFloat = 30
    static let restingEdgeInset: CGFloat = restingBaseEdgeInset - restingGrowth / 2
    static let restingMinHeight: CGFloat = 50
    static let accessoryHitWidth: CGFloat = 44
    static let editorTopInset: CGFloat = 14
    static let controlRailMinHeight: CGFloat = 52
    static let editingMinHeight: CGFloat = 124
    static let editingMaxHeightFraction: CGFloat = 0.46
    static let compactWidthFraction: CGFloat = 0.72
    static let compactMinHeight: CGFloat = 38
    static let compactInset: CGFloat = 8
    static let reliableHitSize: CGFloat = 44

    private static let restingHorizontalInset: CGFloat = 12
    private static let restingVerticalInset: CGFloat = 10
    private static let compactFontScale: CGFloat = 0.82
    private static let restingBottomSpacing: CGFloat = 12 - restingGrowth / 2
    private static let compactBottomSpacing: CGFloat = 22
    private static let editingBottomSpacing: CGFloat = 12

    static func resolve(
        state: ComposerPresentationState,
        containerWidth: CGFloat,
        availableHeight: CGFloat,
        measuredTextHeight: CGFloat,
        scaledLineHeight: CGFloat,
        collapseProgress: ComposerCollapseProgress
    ) -> ComposerLayout {
        let width = max(0, containerWidth)
        let height = max(0, availableHeight)
        let lineHeight = max(0, scaledLineHeight)
        let contentHeight = max(lineHeight, measuredTextHeight)

        if state == .editing {
            return editingLayout(
                width: width,
                availableHeight: height,
                contentHeight: contentHeight
            )
        }

        return previewLayout(
            width: width,
            availableHeight: height,
            lineHeight: lineHeight,
            progress: CGFloat(collapseProgress.value),
            reservesAccessories: state == .resting
        )
    }

    private static func previewLayout(
        width: CGFloat,
        availableHeight: CGFloat,
        lineHeight: CGFloat,
        progress: CGFloat,
        reservesAccessories: Bool
    ) -> ComposerLayout {
        let restingWidth = max(0, width - 2 * restingEdgeInset)
        let compactWidth = max(0, width - 2 * restingBaseEdgeInset) * compactWidthFraction
        let outerWidth = interpolate(restingWidth, compactWidth, progress)

        let restingHeight = max(restingMinHeight, lineHeight + 2 * restingVerticalInset)
            + restingGrowth
        let compactTextHeight = lineHeight * compactFontScale
        let compactHeight = max(
            compactMinHeight,
            compactTextHeight + 2 * compactInset
        )
        let outerHeight = min(
            interpolate(restingHeight, compactHeight, progress),
            availableHeight
        )
        let bottomSpacing = interpolate(restingBottomSpacing, compactBottomSpacing, progress)
        let originX = (width - outerWidth) / 2
        let originY = max(0, availableHeight - bottomSpacing - outerHeight)
        let outerFrame = CGRect(x: originX, y: originY, width: outerWidth, height: outerHeight)

        let horizontalInset = interpolate(restingHorizontalInset, compactInset, progress)
        let verticalLineHeight = interpolate(lineHeight, compactTextHeight, progress)
        let verticalPadding = min(
            interpolate(restingVerticalInset, compactInset, progress),
            max(0, (outerHeight - verticalLineHeight) / 2)
        )
        let leadingReserve: CGFloat = reservesAccessories ? accessoryHitWidth : 0
        let trailingReserve: CGFloat = reservesAccessories ? accessoryHitWidth : 0
        let textWidth = max(
            0,
            outerWidth - 2 * horizontalInset - leadingReserve - trailingReserve
        )
        let textFrame = CGRect(
            x: originX + horizontalInset + leadingReserve,
            y: originY + (outerHeight - verticalLineHeight) / 2,
            width: textWidth,
            height: min(verticalLineHeight, outerHeight)
        )
        let hitWidth = max(reliableHitSize, outerWidth)
        let hitHeight = max(reliableHitSize, outerHeight)
        let restingHitWidth = textFrame.width
        let restingHitX = textFrame.minX
        let compactHitX = (width - hitWidth) / 2
        let hitFrame = CGRect(
            x: interpolate(restingHitX, compactHitX, progress),
            y: outerFrame.midY - hitHeight / 2,
            width: interpolate(restingHitWidth, hitWidth, progress),
            height: hitHeight
        )

        return ComposerLayout(
            outerFrame: outerFrame,
            bottomSpacing: bottomSpacing,
            textFrame: textFrame,
            padding: EdgeInsets(
                top: verticalPadding,
                leading: horizontalInset,
                bottom: verticalPadding,
                trailing: horizontalInset
            ),
            leadingAccessoryReserve: leadingReserve,
            trailingAccessoryReserve: trailingReserve,
            controlRailReserve: 0,
            typographyRole: .interfaceBody,
            fontScale: interpolate(1, compactFontScale, progress),
            previewLineLimit: 1,
            textAreaIsScrollable: false,
            visualFrame: outerFrame,
            hitFrame: hitFrame
        )
    }

    private static func editingLayout(
        width: CGFloat,
        availableHeight: CGFloat,
        contentHeight: CGFloat
    ) -> ComposerLayout {
        let outerWidth = max(0, width - 2 * edgeInset)
        let maximumHeight = availableHeight * editingMaxHeightFraction
        let requestedHeight = max(
            editingMinHeight,
            editorTopInset + contentHeight + controlRailMinHeight
        )
        let outerHeight = min(requestedHeight, maximumHeight)
        let bottomSpacing = editingBottomSpacing
        let originX = (width - outerWidth) / 2
        let originY = max(0, availableHeight - bottomSpacing - outerHeight)
        let outerFrame = CGRect(x: originX, y: originY, width: outerWidth, height: outerHeight)
        let horizontalInset = min(restingHorizontalInset, outerWidth / 2)
        let textHeight = max(0, outerHeight - editorTopInset - controlRailMinHeight)
        let textFrame = CGRect(
            x: originX + horizontalInset,
            y: originY + min(editorTopInset, outerHeight),
            width: max(0, outerWidth - 2 * horizontalInset),
            height: textHeight
        )

        return ComposerLayout(
            outerFrame: outerFrame,
            bottomSpacing: bottomSpacing,
            textFrame: textFrame,
            padding: EdgeInsets(
                top: editorTopInset,
                leading: horizontalInset,
                bottom: 0,
                trailing: horizontalInset
            ),
            leadingAccessoryReserve: 0,
            trailingAccessoryReserve: 0,
            controlRailReserve: controlRailMinHeight,
            typographyRole: .interfaceBody,
            fontScale: 1,
            previewLineLimit: 0,
            textAreaIsScrollable: contentHeight > textHeight,
            visualFrame: outerFrame,
            hitFrame: outerFrame
        )
    }

    private static func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}

enum ComposerShapeToken {
    static let minimumCurvature: CGFloat = 18

    static func shape(for layout: ComposerLayout) -> ConcentricRectangle {
        let minimum = minimumRadius(for: layout)
        return ConcentricRectangle(corners: .concentric(minimum: .fixed(minimum)))
    }

    static func minimumRadius(for layout: ComposerLayout) -> CGFloat {
        if layout.controlRailReserve > 0 {
            return max(minimumCurvature, layout.controlRailReserve / 2)
        }
        return max(minimumCurvature, layout.outerHeight / 2)
    }
}
