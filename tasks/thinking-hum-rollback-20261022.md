# Restore Thinking hum — 2026-10-22

Owner requests rollback after trying system selection. Restore the original 44.1 Thinking hum, preserving the remaining accepted UI, interactions, animation, compiler and decoration behavior. Blueprint fffca08. Do not reset or alter the primary checkout's unrelated Sidebar work.

Restored these four files from rollback/thinking-hum-44-1-20261022 (eb39a65d98116fbd53dccd6ba43cd9e685e8151d): App/Workspace/ThinkingSelectionHaptics.swift, App/Workspace/WorkspaceHaptics.swift, App/Conversation/ComposerThinkingControl.swift, App/Conversation/ComposerThinkingTrack.swift. This restores the 800ms continuous event, intensity 0.48, sharpness 0.12, original envelope, endpoint/commit triggers and lifecycle handling. The selection experiments remain in Git history.

Verification: git diff --exit-code against the rollback tag for App, Config, Resources, Tests and project.yml is clean. Reuse the existing original IPA rather than generate a duplicate of identical production inputs. Its actual macOS optimized build/package run https://github.com/54zhien/Zen-Agent/actions/runs/39615720608 is completed/success, freshly queried. No new compilation or tests run in this rollback.

IPA: C:/Users/Azusa/Documents/Codex/artifacts/2026-10-22-thinking-system-haptics/rollback-hum-44-1/ZenAgent-Composer-44-1.ipa.
Version 44.1, com.zhien.zen. Local SHA-256 and packaged Info.plist reverified: 1e0d08c426b2ffd7bffd045bd248fa43151fffbd7da4a624237ce5e19ed183f2.

No main merge. Device installation remains with the owner.
