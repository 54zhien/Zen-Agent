import Foundation
import GRDB

struct ConversationSearchSource: Equatable, Sendable {
    let conversationID: String
    let partID: String
    let sourceRevision: Int64
    let text: String
}

struct ConversationVectorRecord: Equatable, Sendable, FetchableRecord {
    static let databaseTableName = "conversationVectorRecord"

    let profileID: String
    let conversationID: String
    let partID: String
    let chunkIndex: Int
    let startOffset: Int
    let endOffset: Int
    let sourceRevision: Int64
    let contentHash: String
    let embedding: [Float]

    init(row: Row) throws {
        profileID = row["profileID"]
        conversationID = row["conversationID"]
        partID = row["partID"]
        chunkIndex = row["chunkIndex"]
        startOffset = row["startOffset"]
        endOffset = row["endOffset"]
        sourceRevision = row["sourceRevision"]
        contentHash = row["contentHash"]
        let bytes: Data = row["embedding"]
        guard bytes.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw PersistenceError.constraintViolation
        }
        embedding = Self.decode(bytes)
    }

    init(profileID: String, chunk: ConversationSearchChunk, embedding: [Float]) {
        self.profileID = profileID
        conversationID = chunk.conversationID
        partID = chunk.partID
        chunkIndex = chunk.chunkIndex
        startOffset = chunk.startOffset
        endOffset = chunk.endOffset
        sourceRevision = chunk.sourceRevision
        contentHash = chunk.contentHash
        self.embedding = embedding
    }

    var embeddingData: Data {
        var data = Data(capacity: embedding.count * MemoryLayout<UInt32>.size)
        for component in embedding {
            var bits = component.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decode(_ data: Data) -> [Float] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: MemoryLayout<UInt32>.size).map { offset in
            let bits = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
}
