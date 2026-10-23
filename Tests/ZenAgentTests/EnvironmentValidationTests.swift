import Testing
@testable import ZenAgent

@Suite("Environment input boundaries")
struct EnvironmentValidationTests {
    @Test("keys reject ambiguous names, controls and unbounded input")
    func keys() {
        for value in ["LANGUAGE", "project_name", "_LOCAL", "A1"] { #expect(EnvironmentValidation.allowsKey(value)) }
        for value in ["", "1KEY", "KEY NAME", "KEY\n", "A.B", "中文", String(repeating: "A", count: 129)] {
            #expect(!EnvironmentValidation.allowsKey(value))
        }
    }
    @Test("plain data has a bounded text shape without NUL or malformed variable references")
    func plain() {
        for value in ["", "中文", "https://example.invalid/path", "${BASE}/repo", "first\nsecond"] {
            #expect(EnvironmentValidation.allowsPlain(value))
        }
        for value in ["a\0b", String(repeating: "x", count: 16_385), "${}", "${1BAD}", "${MISSING"] {
            #expect(!EnvironmentValidation.allowsPlain(value))
        }
        #expect(EnvironmentValidation.references(in: "${ROOT}/${ROOT}/${LANG}") == ["LANG", "ROOT"])
    }
}
