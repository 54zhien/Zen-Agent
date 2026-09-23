import Foundation
import Observation

@MainActor
@Observable
final class ComposerSendCoordinator {
    private let conversationID: String
    private let controller: ComposerController
    private let bridge: ComposerRuntimeActionBridge
    private let maxProviderSteps: Int

    private(set) var submission: ComposerSubmissionState = .idle

    @ObservationIgnored private var pendingTextSnapshot: String?
    @ObservationIgnored private var pendingReferencesSnapshot: [QuoteReference]?
    @ObservationIgnored private var pendingAttachmentsSnapshot: [AttachmentReference]?
    @ObservationIgnored private var latestProjection: RunProjection?

    init(
        conversationID: String,
        controller: ComposerController,
        configuration: ConversationComposerConfiguration,
        bridge: ComposerRuntimeActionBridge,
        maxProviderSteps: Int
    ) {
        self.conversationID = conversationID
        self.controller = controller
        self.bridge = bridge
        self.maxProviderSteps = maxProviderSteps
        controller.configuration = configuration
    }

    func beginSend(
        capabilities: Set<ModelCapability>,
        quoteCommitReady: Bool,
        imageInputReady: Bool,
        fileInputReady: Bool,
        submissionID: String
    ) -> SendCommand? {
        guard submission == .idle,
              !submissionID.isEmpty,
              maxProviderSteps > 0,
              ComposerActionPolicy.isSendable(
                draft: controller.draft,
                capabilities: capabilities,
                quoteCommitReady: quoteCommitReady,
                imageInputReady: imageInputReady,
                fileInputReady: fileInputReady
              )
        else { return nil }

        let command = SendCommand(
            conversationID: conversationID,
            text: controller.draft.text,
            references: controller.draft.references,
            attachments: controller.draft.attachments.map { attachment in
                SendAttachment(
                    assetID: attachment.id,
                    versionID: attachment.versionID,
                    fingerprint: attachment.fingerprint,
                    kind: attachment.kind,
                    displayName: attachment.displayName
                )
            },
            providerInstanceID: controller.configuration.providerInstanceID,
            modelID: controller.configuration.modelID,
            maxProviderSteps: maxProviderSteps,
            submissionID: submissionID
        )
        pendingTextSnapshot = command.text
        pendingReferencesSnapshot = command.references
        pendingAttachmentsSnapshot = controller.draft.attachments
        submission = .awaitingAcceptance(submissionID: submissionID)
        return command
    }

    func acceptSend(submissionID: String, projection: RunProjection) {
        guard submission == .awaitingAcceptance(submissionID: submissionID) else { return }

        if let pendingTextSnapshot, controller.draft.text == pendingTextSnapshot {
            controller.draft.text = ""
            controller.draft.selection = ComposerSelection(range: 0..<0)
        }
        if let pendingReferencesSnapshot {
            controller.draft.references.removeAll { current in
                pendingReferencesSnapshot.contains(current)
            }
        }
        if let pendingAttachmentsSnapshot {
            var unmatchedSnapshot = pendingAttachmentsSnapshot
            controller.draft.attachments.removeAll { current in
                guard let index = unmatchedSnapshot.firstIndex(of: current) else { return false }
                unmatchedSnapshot.remove(at: index)
                return true
            }
        }

        pendingTextSnapshot = nil
        pendingReferencesSnapshot = nil
        pendingAttachmentsSnapshot = nil
        submission = .acceptedAwaitingProjection(runID: projection.runID)
    }

    func rejectSend(submissionID: String) {
        guard submission == .awaitingAcceptance(submissionID: submissionID) else { return }
        pendingTextSnapshot = nil
        pendingReferencesSnapshot = nil
        pendingAttachmentsSnapshot = nil
        submission = .idle
    }

    func updateRunProjection(_ projection: RunProjection?) {
        latestProjection = projection
        guard case .acceptedAwaitingProjection(let runID) = submission,
              projection?.runID == runID
        else { return }
        submission = .idle
    }

    @discardableResult
    func handlePrimaryAction() async -> ComposerPrimaryAction {
        if let projection = latestProjection, projection.isActive {
            guard projection.canStop else {
                return .stop(runID: projection.runID, enabled: false)
            }
            do {
                try await bridge.stop(projection.runID)
                if let updated = try await bridge.projection(conversationID) {
                    updateRunProjection(updated)
                }
            } catch {
                // The persisted projection remains the authority after a failed Stop.
            }
            return primaryAction(sendable: false)
        }

        guard submission == .idle else { return .send(enabled: false) }

        let configuration = controller.configuration
        let models: [ModelDescriptor]
        do {
            models = try await bridge.models(configuration.providerInstanceID)
        } catch {
            return .none
        }
        guard controller.configuration == configuration else { return .none }
        guard let selected = models.first(where: {
            $0.providerInstanceID == configuration.providerInstanceID
                && $0.id == configuration.modelID
        }) else { return .none }

        let command = beginSend(
            capabilities: selected.capabilities,
            quoteCommitReady: true,
            imageInputReady: false,
            fileInputReady: false,
            submissionID: UUID().uuidString
        )
        guard let command else { return primaryAction(sendable: false) }

        let runID: String
        do {
            runID = try await bridge.start(command)
        } catch {
            rejectSend(submissionID: command.submissionID)
            return primaryAction(sendable: ComposerActionPolicy.isSendable(
                draft: controller.draft,
                capabilities: selected.capabilities,
                quoteCommitReady: true,
                imageInputReady: false,
                fileInputReady: false
            ))
        }

        let acceptedProjection = (try? await bridge.projection(conversationID))
            ?? RunProjection(runID: runID, state: .preparing)
        acceptSend(submissionID: command.submissionID, projection: acceptedProjection)
        updateRunProjection(acceptedProjection)
        return primaryAction(sendable: false)
    }

    private func primaryAction(sendable: Bool) -> ComposerPrimaryAction {
        ComposerContextAction.resolve(
            projection: latestProjection,
            presentationState: controller.draft.presentationState,
            sendable: sendable,
            hasDraft: !controller.draft.text.isEmpty
                || !controller.draft.references.isEmpty
                || !controller.draft.attachments.isEmpty,
            plusAvailable: false,
            submission: submission
        ).primary
    }
}
