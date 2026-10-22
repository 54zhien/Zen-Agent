import SwiftUI

@main
struct ZenAgentApp: App {
    @State private var shellModel = AppShellModel()

    init() {
        do {
            try FontRegistry.registerBundledFonts()
        } catch {
            // A missing asset is a wiring bug, not a runtime condition to absorb: this is the
            // one place that can name the file, and the alternative is text silently rendering
            // in a fallback face with nothing to notice.
            assertionFailure("Font registration failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1" {
                ConversationPreviewUITestFixture()
            } else if ProcessInfo.processInfo.environment["ZEN_SURFACE_LIFT_UI_TEST"] == "1" {
                SurfaceLiftUITestFixture()
            } else if ProcessInfo.processInfo.environment["ZEN_APP_SPACE_GEOMETRY_UI_TEST"] == "1" {
                if ProcessInfo.processInfo.environment["ZEN_APP_SPACE_GEOMETRY_AX"] == "1" {
                    AppSpaceStaticGeometryFixture().environment(\.dynamicTypeSize, .accessibility3)
                } else {
                    AppSpaceStaticGeometryFixture()
                }
            } else if ProcessInfo.processInfo.environment["ZEN_SURFACE_UI_TEST"] == "1" {
                ConversationSurfaceUITestFixture()
            } else if ProcessInfo.processInfo.environment["ZEN_CONVERSATION_READING_UI_TEST"] == "1" {
                ConversationSurfaceHost {
                    ConversationPaneReadingUITestFixtureView()
                }
                .ignoresSafeArea()
            } else if ProcessInfo.processInfo.environment["ZEN_COMPOSER_GEOMETRY_TEST"] == "1" {
                ConversationSurfaceHost {
                    ComposerUITestFixtureView()
                }
                .ignoresSafeArea()
            } else {
                AppShellRootView(model: shellModel)
            }
#else
            AppShellRootView(model: shellModel)
#endif
        }
    }
}
