import Foundation

enum ComposerPrimaryAction: Equatable, Sendable {
    case none
    case send(enabled: Bool)
    case stop(runID: String, enabled: Bool)
}

enum ComposerSlotToken: Equatable, Sendable {
    case trailing
    case trailingAdjacentLeading
}

enum ComposerSubmissionState: Equatable, Sendable {
    case idle
    case awaitingAcceptance(submissionID: String)
    case acceptedAwaitingProjection(runID: String)
}

struct ComposerContextActionState: Equatable, Sendable {
    let primary: ComposerPrimaryAction
    let voiceTarget: ComposerSlotToken
    let showsVoice: Bool
    let showsPlus: Bool
    let hasDraft: Bool
}

enum ComposerContextAction {
    static func resolve(
        projection: RunProjection?,
        presentationState: ComposerPresentationState,
        sendable: Bool,
        hasDraft: Bool,
        plusAvailable: Bool,
        submission: ComposerSubmissionState
    ) -> ComposerContextActionState {
        let primary: ComposerPrimaryAction
        if let projection, projection.isActive {
            primary = .stop(runID: projection.runID, enabled: projection.canStop)
        } else if submission != .idle {
            primary = .send(enabled: false)
        } else if sendable {
            primary = .send(enabled: true)
        } else {
            primary = .none
        }

        let hasPrimaryAction: Bool
        switch primary {
        case .none:
            hasPrimaryAction = false
        case .send, .stop:
            hasPrimaryAction = true
        }

        return ComposerContextActionState(
            primary: primary,
            voiceTarget: hasPrimaryAction ? .trailingAdjacentLeading : .trailing,
            showsVoice: false,
            showsPlus: plusAvailable && presentationState != .compact,
            hasDraft: hasDraft
        )
    }

    static func trailingFrame(
        layout: ComposerLayout,
        state: ComposerPresentationState
    ) -> CGRect? {
        let size = ComposerGeometry.accessoryHitWidth
        let radius = ComposerShapeToken.minimumRadius(for: layout)

        switch state {
        case .resting:
            guard layout.trailingAccessoryReserve >= size else { return nil }
            return CGRect(
                x: layout.outerFrame.maxX - radius - size / 2,
                y: layout.outerFrame.midY - size / 2,
                width: size,
                height: size
            )
        case .editing:
            guard layout.controlRailReserve >= size else { return nil }
            return CGRect(
                x: layout.outerFrame.maxX - radius - size / 2,
                y: layout.outerFrame.maxY - radius - size / 2,
                width: size,
                height: size
            )
        case .compact:
            return nil
        }
    }

    static func leadingPlusFrame(
        layout: ComposerLayout,
        state: ComposerPresentationState
    ) -> CGRect? {
        let size = ComposerGeometry.accessoryHitWidth
        let radius = ComposerShapeToken.minimumRadius(for: layout)

        switch state {
        case .resting:
            guard layout.leadingAccessoryReserve >= size else { return nil }
            return CGRect(
                x: layout.outerFrame.minX + radius - size / 2,
                y: layout.outerFrame.midY - size / 2,
                width: size,
                height: size
            )
        case .editing:
            guard layout.controlRailReserve >= size else { return nil }
            return CGRect(
                x: layout.outerFrame.minX + radius - size / 2,
                y: layout.outerFrame.maxY - radius - size / 2,
                width: size,
                height: size
            )
        case .compact:
            return nil
        }
    }

}
