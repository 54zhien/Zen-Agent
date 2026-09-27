# Stage 3 reading-position UI gate harness implementation plan

> For the implementer: read Blueprint `Design/Zen Agent 开发规划.md` Stage 3,
> `Design/CONTEXT.md`, and `Design/Zen Agent Conversation UI 与 Composer.md`
> before code. This plan is a CI evidence slice, not Stage 3 device Gate closure.

**Goal:** Exercise the real reusable Conversation Pane when a user reads above
the bottom while assistant content streams into a longer timeline.

**Architecture:** A DEBUG-only launch route supplies a many-Turn projection to
the production `ConversationPaneView` and a controlled live event source. The UI
test scrolls the real timeline, records a visible Turn position, injects new
assistant text, and verifies the reader stays put until choosing the new-content
control. The fixture never changes production navigation or Composer geometry.

**Tech stack:** SwiftUI, XCTest UI tests, XcodeGen, macOS CI.

**Spec:** Blueprint Stage 3 Gate and `Zen Agent Conversation UI 与 Composer.md`
§§4–5, 11–12 at `596a84d4b58769e3e7b838be95edcb43f9e0ec82`.

## Global constraints

- Do not start Stage 5 App Space or add user-facing controls.
- Do not alter approved Composer dimensions, curvature, keyboard motion, or text.
- Use actual `ConversationPaneView`, `ConversationPaneController`, and live event
  path; an isolated state-machine test does not satisfy this slice.
- Keep the test deterministic: controlled events and observable conditions,
  no arbitrary delay as the proof of stability.
- Report the simulator, tests, exact head SHA and CI result. Device scrolling,
  120 Hz performance, Dynamic Type and VoiceOver stay unverified until measured.

## Task 1: Fixture and failing UI test

**Files:** `App/ZenAgentApp.swift`, a focused DEBUG fixture under
`App/Conversation/`, and a new file under `Tests/ZenAgentUITests/`.

- [ ] Add a DEBUG launch environment route for a many-Turn production Pane.
- [ ] Expose a test-only action that delivers a controlled live assistant delta
  to the final Run through `ConversationPaneController.consume`.
- [ ] In the UI test, scroll upward to a visible older Turn and record its
  window position. Inject the delta and assert the Turn stays at the same
  position within a small rendering tolerance, with a new-content control.
- [ ] Tap new content and assert the newest content becomes visible.
- [ ] Include a keyboard show/hide pass while reading, asserting that the
  older Turn remains available and the Composer remains interactive.
- [ ] Ensure the test fails before the fixture/action is wired and passes
  afterward; if the production behavior fails, keep the failing evidence and
  make only the smallest fix justified by the observed root cause.

## Task 2: Verify and record limits

- [ ] Run local syntax/path checks and `git diff --check`.
- [ ] Push the branch, run CI on its exact SHA, and fix only demonstrated
  failures. Preserve the original failure evidence.
- [ ] Report what the UI test proves and what still requires the user's
  iPhone 15 Pro Max on iOS 27.2. Do not mark the Stage 3 device Gate passed.

## CI finding during implementation

At `669b0f570866a1c1c14fd728c11906bcfa4b7228`, the controlled Streaming
delta preserved the older Turn and the new-content control reached the newest
text. The keyboard pass exposed a separate reading-position failure. The actual
Pane ScrollView remained full-screen in the XCTest accessibility tree; an
unnamed 44-point ScrollView was a different element. When the keyboard appeared,
the visible older Turn moved from approximately y=492 to y=129 on the simulator.
The Pane remained in Reading mode, but the movement was obvious. The existing
height-change bridge applies the Split bottom-edge policy to Composer/keyboard
changes too. The repair must preserve the visible reading anchor for Composer
transitions while retaining bottom-edge anchoring for independent Pane resize.
This finding is simulator evidence, not a completed device Gate.

The first Composer-only repair preserved the anchor's fraction of viewport
height. A later keyboard run showed why that was insufficient: with a reading
anchor just above the viewport, the visible marker moved about 40 points even
though the stored fraction was unchanged. The revised repair captures the
anchor's screen-space offset once per Composer transition and rebases its
fraction as the viewport changes. On `a39c4d04b128469febad255c691bfb7d2e40e1ec`,
macOS CI run `36302624168` passed the full suite. In the controlled UI test,
the older marker remained at about y=203–204 across keyboard presentation,
and two blank-space taps dismissed the keyboard. Split bottom-edge regression
tests also passed. This is simulator evidence; the device Gate above is still
open.
