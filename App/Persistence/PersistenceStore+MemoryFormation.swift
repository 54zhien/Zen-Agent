import Foundation
import GRDB

extension PersistenceStore {
    func prepareMemoryFormation(runID: String) throws -> MemoryFormationInput? { nil }

    func commitMemoryCandidates(_ candidates: [MemoryCandidate], from input: MemoryFormationInput) throws { }
}
