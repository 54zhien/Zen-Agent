import Foundation

/// The only JSON boundary for a `RunExecutionSnapshot`.
enum ExecutionSnapshotCodec {
    typealias FormatError = RunExecutionSnapshot.FormatError

    static func encode(_ snapshot: RunExecutionSnapshot) throws -> String {
        let data = try JSONEncoder().encode(snapshot)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ encodedSnapshot: String) throws -> RunExecutionSnapshot {
        try JSONDecoder().decode(
            RunExecutionSnapshot.self,
            from: Data(encodedSnapshot.utf8)
        )
    }
}
