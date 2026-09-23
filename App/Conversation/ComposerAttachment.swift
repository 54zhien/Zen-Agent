/// Draft 中附件在界面上的类别。
enum AttachmentKind: Equatable, Sendable {
    case image
    case file
}

/// Draft 当前引用的附件身份。
struct AttachmentReference: Equatable, Sendable {
    let id: String
    let versionID: String
    let fingerprint: String
    let displayName: String
    let kind: AttachmentKind
}
