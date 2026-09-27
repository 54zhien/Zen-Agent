# Stage 3 device acceptance record

> Status: open. This is a test protocol and evidence ledger, not a passed Gate.
> Blueprint: `Design/Zen Agent 开发规划.md` Stage 3 Gate and
> `Design/Zen Agent Conversation UI 与 Composer.md` §§4–5, 11–12.

## Candidate and device

- Device: iPhone 15 Pro Max, iOS 27.2.
- Candidate: `ZenAgent-Stage4-840a2e2-device-test.ipa`, unsigned Debug for the
  user's self-signing flow; SHA-256
  `72a7224b3ad05342dbcff60ed4bb912beb2abe1dfd69e520aed2fc8faab3d678`.
- Candidate source: `840a2e2f7a0420a01af1c0d2450ea3f7afbaaebb`. Production
  `App/`, `Config/`, `Resources/` and `project.yml` inputs match integrated
  `main` at `4268a687332080e1942beb2747338fb9f8e8bb4b`.
- Simulator CI on that `main` commit passed: run `36290789435`. This does not
  provide device performance or interaction evidence.
- Record signing method and whether installation updated the prior app in
  place. Do not include API keys in screenshots or recordings.

## Behavior checks

For each row, record pass/fail, date, a short observation, and a screen recording
or screenshot when it fails. A skipped row stays unverified.

| ID | Procedure | Expected result | Result |
|---|---|---|---|
| D1 | Send a short message, wait for completion, then send a second message in the same Conversation. | Both requests start and finish; Send becomes available again; the second answer uses the relevant first exchange. | Unverified |
| D2 | Focus the Composer, enter a multi-line unsent draft, tap blank Timeline space, then focus again. | Keyboard and Composer move together; resting preview preserves the draft; refocusing restores the same text and cursor without a stranded Composer. | Unverified |
| D3 | During a longer streaming answer, swipe upward to an older Turn and continue reading until more text arrives. | The older Turn stays at the same reading position; new tokens do not force a jump to the bottom; the new-content control appears when applicable. | Unverified |
| D4 | Tap the new-content control after D3, then scroll and focus/dismiss the keyboard. | The newest content becomes visible; subsequent scroll and keyboard changes do not lose the chosen reading position or freeze the Composer. | Unverified |
| D5 | Build a longer Conversation, revisit older Turns, rotate if supported, and continue streaming. | Scrolling remains responsive; the visible Turn does not jump or duplicate; no persistent blank area or app termination. Record approximate Turn count and any visible hitch. | Unverified |
| D6 | Move the app to background and return before 20 minutes; then repeat after more than 20 minutes from background entry. Open the old Conversation from Recent. | Before the window, the prior Conversation returns; after it, the new Conversation page appears and the old one remains reachable through Recent. | Unverified |
| D7 | With iOS larger text and VoiceOver, inspect a multi-Turn Conversation, Composer, Send/Stop, and the new-content control. | Text remains readable, controls have useful labels and focus order, and required actions remain reachable. Note any clipping or inaccessible control. | Unverified |

## Gate decision

The Stage 3 Gate requires stable long Conversation scrolling, keyboard behavior,
Streaming and reading position before Stage 5 App Space begins. D1–D7 are
device observations. They do not alone establish a 120 Hz or memory baseline;
that needs measured device profiling (for example, Instruments on a Mac with
the same source build). Record those results separately before claiming the
performance and accessibility closure. Until then the Gate stays open.

Soul is not a D1–D7 device check. Its store/binding/prompt behavior is covered
by Stage 4 tests, while the user-facing editor belongs to Stage 5
`Settings → Agent → Soul` after the formal Settings navigation exists.
