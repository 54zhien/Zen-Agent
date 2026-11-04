import CoreGraphics
import Foundation
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

enum ManagedImageAttachmentServiceError: Error, Equatable {
    case unsupportedImage
    case selectedImageUnavailable
    case invalidImage
}

/// Imports only Photos items explicitly returned by the system picker.
final class ManagedImageAttachmentService: Sendable {
    private let files: ManagedFileStore
    private let store: PersistenceStore

    init(files: ManagedFileStore, store: PersistenceStore) {
        self.files = files
        self.store = store
    }

    func importPhoto(_ item: PhotosPickerItem) async throws -> AttachmentReference {
        guard let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) else {
            throw ManagedImageAttachmentServiceError.unsupportedImage
        }
        try Task.checkCancellation()
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ManagedImageAttachmentServiceError.selectedImageUnavailable
        }
        try Task.checkCancellation()
        return try await importImage(
            data: data,
            displayName: Self.displayName(for: type),
            mediaType: type.identifier
        )
    }

    func importImage(data: Data, displayName: String, mediaType: String) async throws -> AttachmentReference {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ManagedImageAttachmentServiceError.invalidImage
        }

        let files = self.files
        let store = self.store
        let importTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try files.ingest(data: data, displayName: displayName, mediaType: mediaType, in: store)
        }

        let descriptor = try await withTaskCancellationHandler {
            try await importTask.value
        } onCancel: {
            importTask.cancel()
        }

        let attachment = AttachmentReference(
            id: descriptor.assetID,
            versionID: descriptor.versionID,
            fingerprint: descriptor.fingerprint,
            displayName: descriptor.displayName,
            kind: .image
        )
        do {
            try Task.checkCancellation()
        } catch {
            try await discardUnreferenced(attachment)
            throw error
        }
        return attachment
    }

    func thumbnailData(for attachment: AttachmentReference, maximumPixelSize: Int = 256) async throws -> Data? {
        guard attachment.kind == .image else { return nil }
        let files = self.files
        let store = self.store
        let sendAttachment = SendAttachment(
            assetID: attachment.id,
            versionID: attachment.versionID,
            fingerprint: attachment.fingerprint,
            kind: .image,
            displayName: attachment.displayName
        )
        let thumbnailTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try files.withVerifiedBlob(for: sendAttachment, in: store) { url in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: CFDictionary = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
                ] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    data as CFMutableData,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                ) else { return nil }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { return nil }
                return data as Data
            }
        }
        return try await withTaskCancellationHandler {
            try await thumbnailTask.value
        } onCancel: {
            thumbnailTask.cancel()
        }
    }

    func discardUnreferenced(_ attachment: AttachmentReference) async throws {
        let files = self.files
        let store = self.store
        try await Task.detached(priority: .utility) {
            _ = try files.removeUnreferencedAsset(
                id: attachment.id,
                in: store,
                protectedAssetIDs: [],
                checkCancellation: {}
            )
        }.value
    }

    private static func displayName(for type: UTType) -> String {
        guard let fileExtension = type.preferredFilenameExtension else { return "图片" }
        return "图片.\(fileExtension)"
    }
}
