import Foundation

enum ProviderFinishDisposition: Equatable {
    case complete
    case toolBatch
    case failed(EndReason)
}

/// A tool fragment alone never authorizes dispatch or a clean completion. Only an
/// explicit semantic finish can release the provider request's outcome.
enum ProviderFinishPolicy {
    static func disposition(
        for reason: FinishReason,
        toolCallCount: Int
    ) -> ProviderFinishDisposition {
        switch reason {
        case .stop:
            return toolCallCount == 0 ? .complete : .failed(.providerFailed)
        case .toolCalls:
            return toolCallCount > 0 ? .toolBatch : .failed(.providerFailed)
        case .length:
            return .failed(.outputLimit)
        case .contentFilter:
            return .failed(.contentFiltered)
        case .interrupted:
            return .failed(.providerInterrupted)
        case .unknown:
            return .failed(.providerFailed)
        }
    }
}
