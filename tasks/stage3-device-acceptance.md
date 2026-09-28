# Stage 3 device acceptance record

> Status: the product owner reported the Stage 3 device Gate closed on
> 2026-09-27. The per-check device evidence below has not yet been supplied;
> unverified rows must not be read as passed tests.
> Blueprint: `Design/Zen Agent 开发规划.md` Stage 3 Gate and
> `Design/Zen Agent Conversation UI 与 Composer.md` §§4–5, 11–12.

## Candidate and device

- Device: iPhone 15 Pro Max, iOS 27.2.
- Last locally supplied candidate: `ZenAgent-Stage4-840a2e2-device-test.ipa`,
  unsigned Debug for the user's self-signing flow; SHA-256
  `72a7224b3ad05342dbcff60ed4bb912beb2abe1dfd69e520aed2fc8faab3d678`.
- Candidate source: `840a2e2f7a0420a01af1c0d2450ea3f7afbaaebb`. Production
  `App/`, `Config/`, `Resources/` and `project.yml` inputs match integrated
  `main` at `4268a687332080e1942beb2747338fb9f8e8bb4b`.
- Simulator CI on that `main` commit passed: run `36290789435`. This does not
  provide device performance or interaction evidence.
- The owner has not identified the exact installed build used for the Gate
  decision. PR #12's keyboard/reading-position repair merged later at
  `9f80b15f835f255b2dffb39db1e4334b429c6936`; the last locally supplied
  IPA above does not contain that repair. Main CI `36305533211` passed on the
  merge commit, including its UI regression test, but is simulator evidence.
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

### Repair follow-up (2026-09-28)

PR #14 is merged at `f775e63610840bc022730f8dfb5e987ad8e498d5` (tested head
`8ee8516`). The old candidate above contains neither #12 nor #14. No replacement
IPA was generated in this closeout. Record the installed build containing the
repairs before treating any of the following as verified:

| ID | Check on the repaired build | Result |
|---|---|---|
| R1 | Force-quit during generation, relaunch and handle the original Conversation; partial output survives, the abandoned request is not replayed, and recovery/Stop has a visible outcome. | Unverified |
| R2 | Make the selected credential unavailable, reopen saved history, and verify reading works while Send reports its unavailable target. | Unverified |
| R3 | Repeat D2–D4 and consecutive Sends; verify Composer focus, keyboard motion and reading position. PR CI had one quick-focus event-synthesis failure before a same-SHA rerun passed. | Unverified |

Integration and entry evidence is recorded in [stage5-entry.md](stage5-entry.md).

The Stage 3 Gate requires stable long Conversation scrolling, keyboard behavior,
Streaming and reading position before Stage 5 App Space begins. On 2026-09-27
the product owner explicitly reported that the Gate was closed. This records
the owner's progression decision, not invented results for D1–D7. The exact
installed build, observed checks, signing/update method, and any recordings
remain to be added to this ledger. In particular, this record does not claim
that PR #12 was exercised on device. D1–D7 remain unverified here until their
observations are supplied.

The Blueprint also calls for 60/120 Hz, memory, Dynamic Type, and VoiceOver
device checks. No measured 120 Hz or memory baseline has been provided. Record
profiling results separately before claiming measured performance or full
accessibility verification; a CI pass cannot supply that evidence.

Soul is not a D1–D7 device check. Its store/binding/prompt behavior is covered
by Stage 4 tests, while the user-facing editor belongs to Stage 5
`Settings → Agent → Soul` after the formal Settings navigation exists.
