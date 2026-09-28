#if DEBUG
import SwiftUI

@MainActor
struct ConversationSurfaceUITestFixture: View {
    private let reading = ProcessInfo.processInfo.environment["ZEN_SURFACE_READING_UI_TEST"] == "1"
    @State private var step = 0
    private let progress: [CGFloat] = [0, 0.5, 1, 0.5]

    var body: some View {
        ConversationSurfaceHost(request: .init(
            to: .init(scale: 0.6, translation: CGSize(width: 0.1, height: -0.1), cornerRadius: 24),
            progress: progress[step]
        )) {
            if reading {
                ConversationPaneReadingUITestFixtureView()
            } else {
                ComposerUITestFixtureView()
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Button("Step Surface") { step = (step + 1) % progress.count }
                .accessibilityIdentifier("surface-test-step")
                .accessibilityValue(String(describing: progress[step]))
                .buttonStyle(.borderedProminent)
                .padding(.top, 100)
                .padding(.leading, 8)
        }
    }
}
#endif
