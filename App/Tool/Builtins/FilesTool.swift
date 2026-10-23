import Foundation

/// Only immutable managed versions can reach the Tool result boundary.
struct FilesTool: ToolExecutable {
    let files: ManagedFileStore
    let store: PersistenceStore
    var descriptor: ToolDescriptor {
        ToolDescriptor(id: "files", displayName: "Files", description: "Read a managed UTF-8 text file by FileAsset identity.",
            inputSchema: .object(["type": .string("object"), "properties": .object(["assetID": .object(["type": .string("string")])]), "required": .array([.string("assetID")]), "additionalProperties": .bool(false)]),
            revision: "1", sideEffect: .none, approvalRequirement: .required,
            actions: [.init(toolID: "files", actionID: "read", descriptorRevision: "1", risk: .low,
                allowsAutomaticApproval: true, allowsConversationGrant: true, resourceRequirement: .file,
                egressRequirement: .providerRequiringApproval)])
    }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent { throw ToolIntentFailure.preparationFailed }
    func prepare(callID: String, argumentsJSON: String, context: ToolPreparationContext) throws -> ToolExecutionIntent {
        let object = try ToolArgumentJSON.object(from: argumentsJSON)
        guard object.count == 1, let id = object["assetID"] as? String, id.utf8.count <= 128,
              let asset = try store.fileAsset(id: id), let version = try store.fileAssetVersion(id: asset.currentVersionID),
              ToolPolicyIdentity.equals(version.assetID, id) else { throw ToolIntentFailure.invalidArguments }
        return try ToolIntentCodec.freeze(descriptor: descriptor, actionID: "read",
            normalizedArgumentsJSON: ToolArgumentJSON.normalizedObject(["assetID": id]),
            resource: .file(assetID: id, versionID: version.id, contentIdentity: version.contentFingerprint),
            destination: context.destination,
            approvalDisclosure: .init(toolDisplayName: "Files", action: "读取文件", targetDescription: "\(asset.displayName) · \(id) · 版本 \(version.id) · \(version.contentFingerprint)",
                keyImpact: "文件内容将进入 Provider \(context.requestConfigSeed.providerInstanceID.rawValue) · \(context.requestConfigSeed.endpoint.absoluteString) 的后续请求。"))
    }

    func validateDependencies(_ intent: ToolExecutionIntent, context: ToolPreparationContext) throws {
        guard intent.destinationScope == context.destination else { throw ToolIntentFailure.dependenciesChanged }
        try validateDependencies(intent)
    }

    func validateDependencies(_ intent: ToolExecutionIntent) throws {
        let attachment = try attachment(for: intent)
        try files.withVerifiedBlob(for: attachment, in: store) { _ in try requireCurrent(attachment) }
    }

    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        let attachment = try attachment(for: intent)
        return try files.withVerifiedBlob(for: attachment, in: store) { url in
            try Task.checkCancellation()
            try requireCurrent(attachment)
            let version = try store.fileAssetVersion(id: attachment.versionID)
            if (version?.byteCount ?? Int64.max) > Int64(ToolResultGuard.maximumUTF8Bytes) {
                return try reference(attachment, reason: "resultTooLarge")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var bytes = Data()
            while bytes.count <= ToolResultGuard.maximumUTF8Bytes {
                try Task.checkCancellation()
                let remaining = ToolResultGuard.maximumUTF8Bytes + 1 - bytes.count
                guard let chunk = try handle.read(upToCount: min(8192, remaining)), !chunk.isEmpty else { break }
                bytes.append(chunk)
            }
            guard bytes.count <= ToolResultGuard.maximumUTF8Bytes else { return try reference(attachment, reason: "resultTooLarge") }
            guard let text = String(data: bytes, encoding: .utf8), ToolResultGuard.isText(text) else { return try reference(attachment, reason: "unsupportedType") }
            return ToolExecutionResult(content: text)
        }
    }

    private func attachment(for intent: ToolExecutionIntent) throws -> SendAttachment {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard case .file(let asset, let version, let fingerprint) = intent.resourceScope,
              let object = try? ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON),
              object.count == 1, object["assetID"] as? String == asset else { throw ToolIntentFailure.invalidScope }
        return SendAttachment(assetID: asset, versionID: version, fingerprint: fingerprint, kind: .file, displayName: "Managed file")
    }

    private func requireCurrent(_ attachment: SendAttachment) throws {
        guard try store.fileAsset(id: attachment.assetID)?.currentVersionID == attachment.versionID else { throw ToolIntentFailure.dependenciesChanged }
    }

    private func reference(_ attachment: SendAttachment, reason: String) throws -> ToolExecutionResult {
        ToolExecutionResult(content: try ToolArgumentJSON.normalizedObject(["kind": "managedFile", "assetID": attachment.assetID,
            "versionID": attachment.versionID, "fingerprint": attachment.fingerprint, "reason": reason]), kind: .reference)
    }
}
