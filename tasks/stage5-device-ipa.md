# Stage 5 device-feedback IPA candidate

The owner authorized the screenshot corrections and a replacement device build.
This packaging branch does not merge the Stage 5 stack. Delivery requires the
source full CI and artifact verification to succeed; physical acceptance stays open.

## Source and scope

- Remote source: `4e943d169bfc75a4f3a5e5cc524b51b5e37c52a8`.
- Source tree: `c5fcb6be6690c1e5a45a369f2ee2510596271ec8`.
- Required source FULL CI: [37332240929](https://github.com/54zhien/Zen-Agent/actions/runs/37332240929).
- Packaging branch: `codex/s5-device-feedback-ipa-20261005`.
- Upstream intent: [Blueprint PR 6](https://github.com/54zhien/Zen-Agent-Blueprint/pull/6).

The workflow checks the exact source ancestor/tree and permits changes only to
itself and this note. App, Tests, Config, resources, XcodeGen inputs and ordinary
CI match that source. The ordinary full CI also runs on the packaging branch.
Build and CI may run concurrently; a built archive alone is not the delivery gate.
Exact CI outcomes, artifact hash and verification receipts accompany the final IPA.

## Corrections and review

The source adds a black Split gutter with continuous surface corners and a white
bounded resize handle; one bottom Composer presentation follows the active Pane.
Each Conversation keeps its own native editor, draft, selection and Run. Sidebar
owns conversation navigation. Lift tracks the finger vertically from the current
position; Split latches its active Pane. Browse cards share a horizontal centerline
and the light App Space canvas is darker gray.

A fresh whole-branch review identified parked keyboard readiness, update-order
focus transfer, Split Sidebar closing containment and obsolete UI assertions.
Native unit/UI reproductions ran before the production fix pass. The final source
keeps parked keyboard completion delivery, retains incoming focus intent, and
admits closing touches on the opposite surface and dock without including Rail controls.
The temporary test profile and workflow narrowing have been removed.

## Test variant

Unsigned Debug, generic iOS / arm64, minimum iOS 26.0, bundle ID `com.zhien.zen`.
Installation requires the owner's signing method. `ZEN_DEVICE_TEST` uses System
Sans interface text. Anthropic Sans is removed from the IPA and UIAppFonts because
its distribution rights remain unverified. Source Han Serif and JetBrains Mono
retain their original files and accompanying OFL licenses.

## Physical acceptance

Check black divider/corners and handle-only resizing; active-Pane draft/send
routing with IME; Sidebar close taps; vertical Lift and cancellation; horizontal
Browse; Return into the original Split arrangement; keyboard and orientation changes.
Record device/OS, installed SHA-256 and source identity. CI does not establish
physical animation comfort, performance, energy use or memory behavior.
