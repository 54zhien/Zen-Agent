import Testing
import UIKit

@testable import ZenAgent

@Suite("Composer target text measurement")
struct ComposerTextMeasurementTests {
    @Test("multiline target height is measured without the visible single-line mode")
    func targetWidthControlsMultilineHeight() {
        let font = UIFont.systemFont(ofSize: 16)
        let text = Array(repeating: "中文输入与 emoji 😀", count: 30).joined(separator: "\n")
        let wide = ComposerTextMeasurement.height(text: text, width: 320, font: font)
        let narrow = ComposerTextMeasurement.height(text: text, width: 160, font: font)
        #expect(wide > font.lineHeight * 20)
        #expect(narrow >= wide)
        #expect(ComposerTextMeasurement.height(text: "", width: 320, font: font)
                == font.lineHeight)
    }
}
