import Foundation
import Testing

@testable import ZenAgent

@Suite("Model provider registry")
struct ModelProviderRegistryTests {
    @Test("selection resolves the exact provider adapter")
    func exactProviderSelection() throws {
        let deepSeek = FakeProvider(id: .deepSeek, modelNames: ["deepseek-model"])
        let openAI = FakeProvider(id: .openAI, modelNames: ["openai-model"])
        let registry = try ModelProviderRegistry(providers: [deepSeek, openAI])

        let resolved = try registry.resolve(
            providerID: .openAI,
            adapterRevision: openAI.adapterRevision
        )

        #expect(resolved.id == .openAI)
        #expect(resolved.descriptor(
            for: ModelID(rawValue: "openai-model"),
            in: ProviderInstance(
                id: ProviderInstanceID(rawValue: "openai-account"),
                providerID: .openAI,
                displayName: "OpenAI",
                baseURL: nil,
                configRevision: .initial,
                credentialReference: nil
            )
        )?.id == ModelID(rawValue: "openai-model"))
    }

    @Test("unknown provider does not fall back to the first registered provider")
    func unknownProviderFailsWithoutFallback() throws {
        let deepSeek = FakeProvider(id: .deepSeek)
        let registry = try ModelProviderRegistry(providers: [deepSeek])

        var failure: Error?
        do {
            _ = try registry.resolve(
                providerID: ProviderID(rawValue: "unknown"),
                adapterRevision: deepSeek.adapterRevision
            )
        } catch {
            failure = error
        }

        #expect(failure as? ModelProviderRegistryError == .unknownProvider(
            ProviderID(rawValue: "unknown")
        ))
    }

    @Test("a changed adapter revision refuses a frozen run")
    func changedAdapterRevisionFailsExplicitly() throws {
        let openAI = FakeProvider(id: .openAI)
        let registry = try ModelProviderRegistry(providers: [openAI])

        var failure: Error?
        do {
            _ = try registry.resolve(providerID: .openAI, adapterRevision: "openai-responses.v2")
        } catch {
            failure = error
        }

        #expect(failure as? ModelProviderRegistryError == .adapterRevisionMismatch(
            providerID: .openAI,
            requested: "openai-responses.v2",
            available: openAI.adapterRevision
        ))
    }
}
