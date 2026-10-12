import SwiftUI

/// The barless Conversation needs its own status-area fade. Keeping the material
/// separate from the timeline preserves its readable inset and scroll geometry.
struct ConversationTopEdgeMaterial: View {
    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.65),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
