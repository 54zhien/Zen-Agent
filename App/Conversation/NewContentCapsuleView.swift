import SwiftUI

struct NewContentCapsuleView: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(count > 1 ? "有新内容（\(count) 轮）" : "有新内容")
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Capsule())
    }
}
