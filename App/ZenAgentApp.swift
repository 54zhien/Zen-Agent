import SwiftUI

/// Stage 0 application entry point.
///
/// This target is deliberately empty of product behaviour. Stage 0 exists to
/// prove that the project can be regenerated from source and that build/test are
/// reproducible — nothing more.
///
/// Explicitly NOT part of Stage 0, per the plan:
///   - DeepSeek (or any) Provider
///   - AgentRuntime / ConversationRuntime
///   - ToolRuntime
///   - Conversation UI / Composer
///   - App Space / Split
///   - Soul / Memory / Skills / MCP / Subagent
///
/// The only code Stage 0 is allowed to add beyond this placeholder is the
/// throwaway persistence spike, which lives in `Spikes/Persistence` and is built
/// into its own target. Keeping the boundary sharp is the point: the persistence
/// engine decision is still open, and anything built on top of the wrong choice
/// would be rewritten.
@main
struct ZenAgentApp: App {
    var body: some Scene {
        WindowGroup {
            StageZeroPlaceholderView()
        }
    }
}

/// Placeholder surface. Exists so the app has something to launch into and the
/// smoke test has a symbol to reference — not a first draft of any real screen.
struct StageZeroPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Zen Agent")
                .font(.title2)
            Text("Stage 0 — build and test baseline only")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
