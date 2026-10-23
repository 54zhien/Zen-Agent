import Foundation
import CryptoKit

enum EnvironmentBindingIdentity {
    static func fingerprint(skillID: String, keys: [String], references: [EnvironmentRevisionReference]) -> String {
        var data = Data()
        let values = ["environment-binding-v1", skillID] + keys.sorted() + references.sorted {
            ($0.variableID, $0.revisionID) < ($1.variableID, $1.revisionID)
        }.flatMap { [$0.variableID, $0.revisionID] }
        for value in values {
            var length = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: value.utf8)
        }
        return "env-v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
