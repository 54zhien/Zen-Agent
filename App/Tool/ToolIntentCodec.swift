import Foundation

enum ToolIntentFailure: String, Error, Sendable {
    case invalidArguments, preparationFailed, malformedIntent, unsupportedVersion
    case legacyIntentRequiresReapproval, descriptorChanged, actionChanged, invalidScope
    case dependenciesChanged

    var resultContent: String { "Tool intent rejected: \(rawValue)." }
}

enum ToolIntentCodec {
    static func decodeForDisplay(_ json: String) throws -> ToolExecutionIntent {
        try JSONDecoder().decode(ToolExecutionIntent.self, from: Data(json.utf8))
    }

    static func validate(_ intent: ToolExecutionIntent, descriptor: ToolDescriptor) throws {
        // Conservative, unused signature for compiling behavioral RED.
        throw ToolIntentFailure.legacyIntentRequiresReapproval
    }
}
