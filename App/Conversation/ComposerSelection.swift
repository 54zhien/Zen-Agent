/// Draft 内的选择范围。空范围表示光标。
struct ComposerSelection: Equatable, Sendable {
    let range: Range<Int>
}
