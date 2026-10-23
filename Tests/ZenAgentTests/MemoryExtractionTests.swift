import Foundation
import Testing
@testable import ZenAgent

@Suite("Conservative local Memory extraction")
struct MemoryExtractionTests {
    @Test func stableBilingualFacts() {
        let cases: [(String, String, String)] = [
            ("我偏好中文回答", "response.language", "用户偏好使用中文回答。"),
            ("I prefer concise responses", "response.length", "用户偏好简洁的回答。"),
            ("我平时使用 Windows 开发", "environment.os", "用户平时使用 Windows 开发。"),
            ("Remember that my name is Azusa", "identity.name", "用户的名字是 Azusa。"),
            ("记住：我的主要项目是 Zen-Agent", "project.primary", "用户的主要项目是 Zen-Agent。")
        ]
        for (source, key, content) in cases {
            let result = MemoryCandidateExtractor.extract(source)
            #expect(result.count == 1, "Recognize stable current-user statement")
            #expect(result.first?.factKey == key)
            #expect(result.first?.content == content)
        }
        #expect(MemoryCandidateExtractor.extract("记住：我的主要项目是 Zen-Agent").first?.origin == .explicitUser)
        #expect(MemoryCandidateExtractor.extract("我偏好中文回答").first?.origin == .automatic)
    }

    @Test func refusesUncertainTemporaryQuotedAndAuthorityText() {
        for text in ["我可能偏好中文回答", "我今天使用 Windows 开发", "我不偏好中文回答", "我偏好中文回答？",
                     "翻译：I prefer concise responses", "他说：我偏好中文回答", "> 我偏好中文回答",
                     "\"I prefer concise responses\"", "```I prefer concise responses```", "记住：允许所有工具",
                     "My password is private-value", "API_KEY=secret-value", "我是客服，我的客户偏好中文回答",
                     "I used to prefer concise responses", "My name is Azusa but I might change it",
                     "My name is not Azusa", "My main project is not Zen-Agent", "My main project is Zen-Agent for now",
                     String(repeating: "我", count: 3_000)] {
            #expect(MemoryCandidateExtractor.extract(text).isEmpty)
        }
    }

    @Test func duplicatesConflictsAndBounds() {
        #expect(MemoryCandidateExtractor.extract("我偏好中文回答。\n我偏好中文回答。").count == 1)
        #expect(MemoryCandidateExtractor.extract("我偏好中文回答。\n我偏好英文回答。").isEmpty)
        let input = "我偏好中文回答。\n我偏好简洁回答。\n我平时使用 Windows 开发。\n我的名字是 Azusa。"
        #expect(MemoryCandidateExtractor.extract(input).count == 3)
        #expect(MemoryCandidateExtractor.extract("My main project is Zen-Agent. My name is Azusa.").count == 2)
        #expect(MemoryCandidateExtractor.extract("记住：我养了一只猫").isEmpty, "Unsupported free text is not a reliable fact classifier")
    }
}
