import Foundation

struct OpenAIEmbeddingProvider: EmbeddingProvider {
    static let defaultModelID = "text-embedding-3-small"
    static let defaultDimensions = 1_536

    let transport: any HTTPTransport

    var providerID: ProviderID { .openAI }
    var adapterRevision: String { "openai-embeddings.v1" }
    var modelID: String { Self.defaultModelID }
    var dimensions: Int { Self.defaultDimensions }

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    func embed(
        _ inputs: [String],
        instance: ProviderInstance,
        credentialBinding: CredentialBindingSnapshot,
        credentials: any CredentialStoring
    ) async throws -> [[Float]] {
        try Self.checkCancellation()
        guard instance.providerID == providerID,
              instance.credentialReference == credentialBinding.reference else {
            throw EmbeddingProviderFailure.unsupportedProvider
        }

        let secret: SecretValue
        do {
            guard let resolved = try credentials.resolve(
                frozenReference: credentialBinding.reference,
                generation: credentialBinding.generation
            ) else {
                throw EmbeddingProviderFailure.credentialMissing
            }
            secret = resolved
        } catch let failure as EmbeddingProviderFailure {
            throw failure
        } catch let error as CredentialError {
            switch error {
            case .notFound:
                throw EmbeddingProviderFailure.credentialMissing
            case .authenticationRequired:
                throw EmbeddingProviderFailure.credentialRejected
            case .bindingMoved:
                throw EmbeddingProviderFailure.credentialRejected
            case .unavailable, .failed:
                throw EmbeddingProviderFailure.credentialUnavailable
            case .alreadyExists:
                throw EmbeddingProviderFailure.credentialUnavailable
            }
        }

        let body = try JSONEncoder().encode(EmbeddingRequest(
            input: inputs,
            model: modelID,
            dimensions: dimensions,
            encodingFormat: "float"
        ))
        let request = HTTPRequest(
            method: .post,
            url: OpenAIProvider.resolvedEndpoint(for: instance).deletingLastPathComponent().appending(path: "embeddings"),
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(secret.revealed)",
            ],
            body: body
        )

        try Self.checkCancellation()
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HTTPTransportError {
            switch error {
            case .cancelled:
                throw EmbeddingProviderFailure.cancelled
            case .httpStatus(let response), .errorBodyTimeout(let response, _):
                if response.status == 401 || response.status == 403 {
                    throw EmbeddingProviderFailure.credentialRejected
                }
                throw EmbeddingProviderFailure.requestRejected(status: response.status)
            case .networkFailure, .inactivityTimeout, .streamInterrupted:
                throw EmbeddingProviderFailure.transportFailure
            }
        } catch is CancellationError {
            throw EmbeddingProviderFailure.cancelled
        } catch {
            throw EmbeddingProviderFailure.transportFailure
        }

        try Self.checkCancellation()
        guard (200..<300).contains(response.status) else {
            if response.status == 401 || response.status == 403 {
                throw EmbeddingProviderFailure.credentialRejected
            }
            throw EmbeddingProviderFailure.requestRejected(status: response.status)
        }

        let decoded: EmbeddingResponse
        do {
            decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: response.body)
        } catch {
            throw EmbeddingProviderFailure.malformedResponse
        }
        guard decoded.model == modelID,
              decoded.data.count == inputs.count,
              decoded.data.map(\.index).sorted() == Array(0..<inputs.count) else {
            throw EmbeddingProviderFailure.malformedResponse
        }

        let vectors = decoded.data.sorted { $0.index < $1.index }.map { item in
            item.embedding.map(Float.init)
        }
        guard vectors.allSatisfy({ vector in
            vector.count == dimensions && vector.allSatisfy(\.isFinite)
        }) else {
            throw EmbeddingProviderFailure.malformedResponse
        }
        try Self.checkCancellation()
        return vectors
    }

    private static func checkCancellation() throws {
        guard !Task.isCancelled else { throw EmbeddingProviderFailure.cancelled }
    }
}

private struct EmbeddingRequest: Encodable {
    let input: [String]
    let model: String
    let dimensions: Int
    let encodingFormat: String

    enum CodingKeys: String, CodingKey {
        case input
        case model
        case dimensions
        case encodingFormat = "encoding_format"
    }
}

private struct EmbeddingResponse: Decodable {
    struct Item: Decodable {
        let embedding: [Double]
        let index: Int
    }

    let data: [Item]
    let model: String
}
