import Foundation

extension FilesTool {
    func prepareMutation(callID: String, kind: ManagedFileToolMutationKind,
        arguments: [String: Any], context: ToolPreparationContext) throws -> ToolExecutionIntent {
        if kind == .delete, sessions == nil { throw ToolIntentFailure.preparationFailed }
        let expectedKeys: Set<String> = switch kind {
        case .create: ["displayName", "content"]
        case .modify: ["assetID", "expectedVersionID", "content"]
        case .delete: ["assetID", "expectedVersionID"]
        }
        guard Set(arguments.keys) == expectedKeys else { throw ToolIntentFailure.invalidArguments }
        let assetID: String
        let name: String
        let resource: ToolResourceScope
        var normalized: [String: Any] = ["action": kind.rawValue]
        if kind == .create {
            guard let supplied = arguments["displayName"] as? String, supplied.utf8.count <= 256 else {
                throw ToolIntentFailure.invalidArguments
            }
            assetID = "tool-\(callID)"
            name = ManagedFileStore.safeDisplayName(supplied)
            resource = .target(assetID)
        } else {
            guard let id = arguments["assetID"] as? String,
                  let expected = arguments["expectedVersionID"] as? String,
                  let asset = try store.fileAsset(id: id), ToolPolicyIdentity.equals(asset.currentVersionID, expected),
                  let version = try store.fileAssetVersion(id: expected), ToolPolicyIdentity.equals(version.assetID, id) else {
                throw ToolIntentFailure.dependenciesChanged
            }
            assetID = id; name = asset.displayName
            resource = .file(assetID: id, versionID: expected, contentIdentity: version.contentFingerprint)
            normalized["expectedVersionID"] = expected
        }
        normalized["assetID"] = assetID
        var impact: String
        if kind == .delete {
            impact = "从 Workspace 删除该逻辑文件；被消息、草稿、待提交附件或运行使用时拒绝删除。"
        } else {
            guard let content = arguments["content"] as? String, ToolResultGuard.isText(content),
                  content.utf8.count <= ToolResultGuard.maximumUTF8Bytes else { throw ToolIntentFailure.invalidArguments }
            let digest = ManagedFileStore.fingerprint(of: Data(content.utf8))
            normalized["content"] = content
            normalized["displayName"] = name
            normalized["newVersionID"] = "tool-version-\(callID)"
            normalized["newFingerprint"] = digest
            impact = "发布新版本：\(content.utf8.count) UTF-8 字节，\(digest)。历史消息引用保持原版本。"
        }
        impact += " 结果引用进入 Provider \(context.requestConfigSeed.providerInstanceID.rawValue) · \(context.requestConfigSeed.endpoint.absoluteString)。"
        return try ToolIntentCodec.freeze(descriptor: descriptor, actionID: kind.rawValue,
            normalizedArgumentsJSON: ToolArgumentJSON.normalizedObject(normalized), resource: resource,
            destination: context.destination, approvalDisclosure: .init(toolDisplayName: "Files",
                action: kind == .create ? "创建文件" : kind == .modify ? "修改文件" : "删除文件",
                targetDescription: "\(name) · \(assetID) · 版本 \(normalized["expectedVersionID"] as? String ?? normalized["newVersionID"] as? String ?? "")",
                keyImpact: impact))
    }

    func validateMutationDependencies(_ intent: ToolExecutionIntent) throws {
        let value = try mutationPayload(intent)
        if value.kind == .create {
            guard try store.fileAsset(id: value.assetID) == nil else { throw ToolIntentFailure.dependenciesChanged }
        } else {
            let attachment = SendAttachment(assetID: value.assetID, versionID: value.expectedVersionID ?? "",
                fingerprint: value.originalFingerprint, kind: .file, displayName: value.name)
            try files.withVerifiedBlob(for: attachment, in: store) { _ in
                guard let expected = value.expectedVersionID,
                      let current = try store.fileAsset(id: value.assetID), ToolPolicyIdentity.equals(current.currentVersionID, expected) else {
                    throw ToolIntentFailure.dependenciesChanged
                }
            }
        }
    }

    func executeMutation(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        let payload = try mutationPayload(intent)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let binding = ToolIntentBinding.make(String(decoding: try encoder.encode(intent), as: UTF8.self))
        guard let call = try store.toolCall(id: idempotencyKey), let json = call.executionIntent,
              ToolPolicyIdentity.equals(ToolIntentBinding.make(json), binding) else { throw ToolIntentFailure.dependenciesChanged }
        if let receipt = try store.toolFileOperation(callID: call.id, attempt: call.attempt, intentBinding: binding) {
            return ToolExecutionResult(content: receipt.resultJSON, kind: .reference)
        }
        try validateMutationDependencies(intent)
        let mutation = ManagedFileToolMutation(callID: call.id, attempt: call.attempt, intentBinding: binding,
            kind: payload.kind, assetID: payload.assetID, versionID: payload.versionID,
            expectedVersionID: payload.expectedVersionID, fingerprint: payload.fingerprint)
        let files = files, store = store
        let signal = FileOperationCancellation()
        if payload.kind == .delete {
            guard let sessions else { return .failure(.dependencyUnavailable) }
            do {
                let removed = try await sessions.withFileRemovalReservation(assetID: payload.assetID) {
                    let writer = Task.detached { try files.removeToolAsset(mutation, in: store, checkCancellation: { try signal.check() }) }
                    return try await withTaskCancellationHandler { try await writer.value } onCancel: {
                        signal.cancel(); writer.cancel()
                    }
                }
                guard removed else { return .failure(.resourceInUse) }
            } catch ManagedFileStoreError.assetRemovedCleanupPending {
                return try ManagedFileToolReference.result(assetID: mutation.assetID, versionID: mutation.versionID,
                    fingerprint: mutation.fingerprint, reason: "removedFromWorkspaceCleanupPending")
            }
        } else {
            guard let data = payload.data else { throw ToolIntentFailure.invalidArguments }
            let writer = Task.detached {
                try files.writeToolFile(data: data, displayName: payload.name, mutation: mutation,
                    in: store, checkCancellation: { try signal.check() })
            }
            _ = try await withTaskCancellationHandler { try await writer.value } onCancel: {
                signal.cancel(); writer.cancel()
            }
        }
        guard let receipt = try store.toolFileOperation(callID: call.id, attempt: call.attempt, intentBinding: binding) else {
            throw ToolIntentFailure.dependenciesChanged
        }
        return ToolExecutionResult(content: receipt.resultJSON, kind: .reference)
    }

    func confirmedResult(_ intent: ToolExecutionIntent, idempotencyKey: String) throws -> ToolExecutionResult? {
        guard let call = try store.toolCall(id: idempotencyKey), let json = call.executionIntent else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let binding = ToolIntentBinding.make(String(decoding: try encoder.encode(intent), as: UTF8.self))
        guard ToolPolicyIdentity.equals(ToolIntentBinding.make(json), binding) else { throw ToolIntentFailure.dependenciesChanged }
        guard let receipt = try store.toolFileOperation(callID: call.id, attempt: call.attempt, intentBinding: binding) else { return nil }
        return ToolExecutionResult(content: receipt.resultJSON, kind: .reference)
    }

    private struct MutationPayload: Sendable {
        let kind: ManagedFileToolMutationKind
        let assetID: String
        let versionID: String
        let expectedVersionID: String?
        let originalFingerprint: String
        let fingerprint: String
        let data: Data?
        let name: String
    }

    private func mutationPayload(_ intent: ToolExecutionIntent) throws -> MutationPayload {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        guard let action = intent.policyAction?.actionID, let kind = ManagedFileToolMutationKind(rawValue: action),
              let args = try? ToolArgumentJSON.object(from: intent.normalizedArgumentsJSON),
              args["action"] as? String == action, let asset = args["assetID"] as? String else { throw ToolIntentFailure.invalidArguments }
        let expected = args["expectedVersionID"] as? String
        let original: String
        if kind == .create {
            guard intent.resourceScope == .target(asset) else { throw ToolIntentFailure.invalidScope }
            original = ""
        } else {
            guard case .file(let id, let version, let fingerprint) = intent.resourceScope,
                  ToolPolicyIdentity.equals(id, asset), expected.map({ ToolPolicyIdentity.equals(version, $0) }) == true else { throw ToolIntentFailure.invalidScope }
            original = fingerprint
        }
        if kind == .delete {
            guard Set(args.keys) == ["action", "assetID", "expectedVersionID"], let expected else { throw ToolIntentFailure.invalidArguments }
            return MutationPayload(kind: kind, assetID: asset, versionID: expected, expectedVersionID: expected,
                originalFingerprint: original, fingerprint: original, data: nil, name: "Managed file")
        }
        var keys: Set<String> = ["action", "assetID", "newVersionID", "newFingerprint", "displayName", "content"]
        if kind == .modify { keys.insert("expectedVersionID") }
        guard Set(args.keys) == keys, let version = args["newVersionID"] as? String,
              let digest = args["newFingerprint"] as? String, let content = args["content"] as? String,
              let name = args["displayName"] as? String, content.utf8.count <= ToolResultGuard.maximumUTF8Bytes,
              ToolResultGuard.isText(content) else { throw ToolIntentFailure.invalidArguments }
        let data = Data(content.utf8)
        guard ManagedFileStore.fingerprint(of: data) == digest else { throw ToolIntentFailure.dependenciesChanged }
        return MutationPayload(kind: kind, assetID: asset, versionID: version, expectedVersionID: expected,
            originalFingerprint: original, fingerprint: digest, data: data, name: name)
    }
}
