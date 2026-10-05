# Stage 5 device-test IPA

The owner authorized an IPA on 2026-10-05 after the remaining Stage 5 code gates
and whole-stage review. This branch packages the tested source; it does not merge
the Stage 5 stack or establish physical-device acceptance.

## Source and scope

- Tested remote source: `c3dc2ba359509fa4b70afb30c044560cde0cda27`.
- Source tree: `183e1c55822081f83664d46eeaa553c4458a53c6`.
- FULL CI: push `37258223980`, PR `37258227083`; guard `37258227085`, all passed.
- Each phone run: 942 Swift tests / 151 suites, 20 XCTest, 54 UI tests with one
  expected Pad-only skip, zero failures and no test-host restart/retry.
- Dedicated native iPad simulator regression passed in both runs.
- Packaging branch: `codex/s5-device-ipa-20261005`.

The existing Stage 4 unsigned-device workflow is renamed and scoped to this
candidate. Its guard requires the exact tested ancestor/tree and allows only
that workflow rename and this note. App, Tests, Config, resources, project inputs
and the ordinary CI workflow remain unchanged. Windows static checks are only
preflight; the macOS build and artifact verification determine success.

## Test variant

Unsigned Debug, generic iOS / arm64, minimum iOS 26.0, bundle ID `com.zhien.zen`.
Installation requires the owner's signing method. The existing `ZEN_DEVICE_TEST`
variant uses System Sans for interface text; Anthropic Sans is removed from the
IPA and `UIAppFonts` because its distribution rights remain unverified. Source
Han Serif and JetBrains Mono retain their original files and accompanying OFL
licenses. This variant cannot validate the development-only interface font.

The workflow supplies IPA integrity checks, SHA-256, tested source identity,
packaging commit/tree, workflow run and Xcode version in its output. Exact build
result and local artifact checks are recorded alongside the downloaded IPA.
The repository's ordinary full CI also runs on this branch.

## Physical acceptance

Use [the Stage 5 handoff](stage5-review-handoff.md) for the device checklist.
Record device/OS, installed IPA SHA-256 and source identity before testing.
Prioritize cold-launch initial Lift, Lift/Return, Chinese IME, retained drafts,
split axes/divider/rotation, native file import/export and Settings persistence.
Measure Ink/frame pacing, energy, memory and reading/input comfort on hardware;
exercise VoiceOver and Dynamic Type. The historical Browse initial-Lift failure
cause remains unresolved; passing instrumented CI does not prove causal repair.
