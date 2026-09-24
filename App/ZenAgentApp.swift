import SwiftUI

@main
struct ZenAgentApp: App {

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
            AppShellRootView()
        }
    }
}
