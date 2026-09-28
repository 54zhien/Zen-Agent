# S5-03 — continuous Surface Lift / Return

Slice evidence; contract: [implementation plan](../Docs/Plans/2026-09-28-s5-03-lift-return.md).
The final verification/review section below records the current gate. Earlier
pending statements are historical checkpoints, not the current test result.
Base `e679abf2faf556d08f217795570f9f49077c4c14`, Blueprint
`596a84d4b58769e3e7b838be95edcb43f9e0ec82`.

## State boundary

Value-only presentation state distinguishes Full, armed, lifting, settling and Card.
Long press alone never commits Card. Finite drag progress can reverse; unsafe input
invalidates the current gesture. Settlement identity rejects late callbacks. Return
can start from a captured visible position. This does not own a Pane, Draft or Run.

The current-gesture IME policy refuses Lift and preserves input; it never queues or
automatically replays navigation after composition. This reversible implementation
ruling follows the upstream exclusion of Editing/marked text. The optional owner
preference question remains available. Keyboard transition is independently unsafe,
including a hardware keyboard with no onscreen height. UIKit must supply actual
readiness; pure state tests alone do not establish that wiring.

## Evidence

- S5-02 main CI36383328968 attempt1 passed668 Swift Testing/105 suites,20XCTest units,
  8UI tests. Its merged tree equals tested `48fdc62`; primary Desktop main synchronized.
- Initial S5-03 candidate `efbda712d5ce79ddadeed9ef87b780a91e662b51`, run36384225700,
  cancelled when replaced by test-only macro compatibility correction. Not RED evidence.
- Corrected candidate `95ff22f4c9624b5e95cec8b7f2b80b24b2a7c8f5`,
  [CI36384393779](https://github.com/54zhien/Zen-Agent/actions/runs/36384393779) attempt1:
  App build passed; compiled behavioral RED675 Swift Testing/106 suites with55 issues,
  all in SurfaceLiftStateTests.20XCTest units and8UI tests passed; one Swift Testing
  run start, no test-host restart. No production input/host/Runtime path changed.
- At this initial checkpoint, Task1 GREEN and Task2 integration were still pending.
  Subsequent exact-commit results below supersede that status; [PR #18](https://github.com/54zhien/Zen-Agent/pull/18)
  contains the current candidate and integration state.

Threshold12pt/180pt/0.5 is a calibration starting point, not a permanent product rule.
Task2 uses uniform live-content scaling plus an outer crop to the Current card boundary;
it must prove continuous endpoints and stable internal layout before real handoff.
Catalog/real summary previews remain S5-04; browse/Split/creation/decoration remain later.
No physical-device interaction/IME/readability/VoiceOver/performance evidence yet;
Stage5/Gate A remain open. No dependency, schema, signing or build-setting change.

## Task1 GREEN and Task2 entry

Core candidate `af284fdcf768c32b83b63264b4a1b9379a3ba1c4`,
[CI36385602064](https://github.com/54zhien/Zen-Agent/actions/runs/36385602064) attempt1:
App/XcodeGen build passed;675 Swift Testing/106 suites,20XCTest units,8UI tests passed.
Pure state only; production Lift is not complete. Task2 RED adds normalized crop
interface defaults, deliberately Full-only target geometry and unbound presentation
transport, real host/selection/overlay assertions and three real-gesture UI acceptance
tests before routing exists. Compiler errors and missing-type failures do not count.

## Task2 compiled RED and candidate implementation

Candidate `7089f0f0f61fae3d29ae35aa52d9211218cd060c`,
[CI36388152797](https://github.com/54zhien/Zen-Agent/actions/runs/36388152797) attempt1:
XcodeGen/App build passed;684 Swift Testing/108 suites failed with41 issues:
6 native-readiness,20 geometry,15 host assertions.20XCTest units passed;
11UI tests had3 failures at the absent new fixture guard; existing8UI passed.
One Swift Testing run start, no test-host restart. Real markedTextRange creation
passed, proving the native candidate-range test ran. Superseded runs are not RED.

The candidate implementation binds the same hosting child to uniform cover/crop
geometry, an interruptible UIKit animator and the real Composer recognizer. Current
suppresses live editing interaction/accessibility descendants while retaining the
editor; Full restores them. Actual native input and screen-filtered keyboard
notifications refuse unsafe gestures, mounted text-source selections aggregate,
and Scene/viewport/conversation/overlay changes invalidate. No queued IME gesture.
The DEBUG route uses the same driver with a real long-reading Pane.

At this checkpoint, full implementation CI and whole-branch review were pending. The UI
query for Current uses any accessibility element with its identifier to accommodate
its semantic button role; existence/tap/absence assertions remain required.

## Integration regression and late-event fix

`d2cb4ff`, [CI36390325055](https://github.com/54zhien/Zen-Agent/actions/runs/36390325055)
attempt1 built the App and passed684 Swift Testing/108 suites and20XCTest units.
The three new Lift UI tests passed, including actual drag/Return and older-message
rendered position; one old immediate Chinese-value assertion failed, so the full
CI was not green. Its same condition had failed before native Lift was introduced
in S5-02. Preserve that observation without attributing or claiming to repair it.

Test-only `ca558f289e4a0e033e3a9d7ab25fd69cd14d2d4c`,
[CI36391582005](https://github.com/54zhien/Zen-Agent/actions/runs/36391582005) attempt1:
686 Swift Testing/108 suites failed one actual-host assertion: ignored late
drag/end events overwrote the animator model endpoint with settlement start progress.
20XCTest units and all11UI tests passed, including the same Chinese condition with
an observed-value diagnostic. One test-run start; no restart. Native source
registration/dismantle and the actual-driver retained-owner variant passed.

The fix ignores drag/end outside armed/lifting before any presentation write.
Return captures pixels only in phases that can return. Gesture coordinates remain
owned by the native interaction helper; the unused coordinator point argument is
removed. Supplemental checks retain native editor selection and settled safe area,
and verify configured transport/editor/recognizer teardown. Full GREEN and review
are still required before integration.

## Final verification and review

Candidate `1d2f6ff8e8c0ea8ec7f03ce02a63f65ab4e70236`,
[CI36393307077](https://github.com/54zhien/Zen-Agent/actions/runs/36393307077) attempt1:
XcodeGen/App build,687 Swift Testing/108 suites,20XCTest units and11UI tests passed;
Guard36393307098 passed. One Swift Testing run start, no host restart. Native
transport teardown, editor selection/settled safe area and late-event regression
passed. The old Chinese immediate-value condition passed; its cause remains
unattributed and no input-sync repair is claimed.

The fresh read-only whole-branch review found one Important issue: the controller
can capture and retarget an interrupted animation, but production Surface activation
was only available at Card. Settling froze the child without exposing an interruption
entry. No Critical or Minor findings. Actual Surface accessibility/custom-action and
root visible-animation hit-testing regressions are published as test-only `8caf1d5`,
CI36395369110. That run built and failed four new test assertions, with all other
687 Swift Testing tests,20XCTest units and11UI tests passing. It is not valid
entry-path RED: the first timed sample had already reached Card and the second
had no presentation layer. Do not attribute those harness precondition failures
to the missing entry or claim the fix was verified.

Controlled test-support candidate `0c965e65bdade6576d2637a8fd4694c5103562fd`,
CI36397150474, uses a connected UIWindowScene and pauses/scrubs the actual native
animator before yielding. A DEBUG read-only animator accessor supplies clock
control; production activation/hit-testing are unchanged. Scene/layer/mask
preconditions are required, not skipped or mocked. Target behavior RED and a
complete post-fix GREEN remain required before merge.

That controlled run executed all689 Swift Testing tests/108 suites and failed
10 issues only in the two new regressions. Actual Scene, paused settling,
presentation layer/mask and intermediate geometry preconditions passed. Nine
failures expose missing production activation/Return consequences; one proves a
visible point above the model endpoint did not hit the frozen Surface.
20XCTest units and all11UI tests passed. This is the valid compiled behavior RED.

The minimum fix exposes the existing Return for Card and settling, keeps the
editor frozen, and routes root hit-testing and touch release through the visible
presentation tree and animated mask. The animator explicitly uses manual
hit-testing. Repeated animated Return preserves the existing Full destination;
an explicit nonanimated Return retains its immediate-settlement behavior.
The same new assertions remain unchanged. Full post-fix GREEN is pending.

Reentry during a Return acknowledges its existing Full destination/token rather than
restarting the animator. A fresh Lift remains subject to Full readiness. The editor
stays frozen during settlement; interruption belongs to the outer Surface. Touch
coordinates must follow the visible animated mask rather than the model endpoint.

Physical-device Gate A and real hardware-keyboard/IME/VoiceOver/Switch Control/
Reduce Motion usability remain unobserved. No device comfort or performance claim.

## Recorded implementation rulings and review limits

These are decisions in execution order, with costs if wrong. The initial
question-pending ruling is historical and superseded by the explicit refusal
ruling. The presentation-only owner ruling would cost a transport/ownership
refactor if wrong. Repeated Return refers to animated user activation; explicit
nonanimated Return keeps its immediate-settlement contract. Device evidence,
later slices and the unattributed historical Chinese assertion remain open.
- Ruling: pure state Task1 independent of pending IME entry policy; both policies forbid motion while marked text exists. Keep question pending, no real entry/queue policy until answer. Cost if wrong: entry orchestration adjustment, pure safety invariant unchanged.
- Ruling: single presentation value state with UUID settlement token; no Runtime/Composer data ownership. Real bridge needed Task2, core alone is not delivered Lift.
- Ruling: IME preference question was optional, not additional permission; after sufficient reply opportunity adopt reversible current-gesture refusal from explicit upstream Editing/marked-text exclusion. No auto replay/queue, preserve input and require fresh gesture. User continuation authorizes reversible implementation; time is not approval. Cost if wrong: entry orchestration change to requested queue policy. Supersedes previous waiting wording; preference question remains available.
- Ruling: Current Return item uses semantic button accessibility and custom action; UI query changed from otherElements to descendants(any) for the same identifier/existence/tap assertions, so a genuine UIKit button role neither false-fails the Return query nor false-passes absence checks. This is harness role independence, not weaker behavior. Current compiled RED still fails absent actual fixture before role-dependent checks. Cost if wrong: accessibility role/query revision.
- Ruling: coordinate origin stays solely in native helper; remove unused presenter arm(at:) argument rather than implying a second coordinate owner. Cost if wrong: restore explicit coordinate input if future targeting truly needs it. Additional native lifecycle/selection/settledsafearea coverage nowpartofGREEN candidate. No Chinese text-sync repair claim, observation remains intermittent/unattributed.
- Ruling: repeated Return activation during returning settlement acknowledges the existing Full destination without replacing token/animator; fresh Lift requires Full readiness — avoids repeated taps starving completion while preserving editor freeze — cost if wrong: new explicit reverse/gesture contract during Return.
- Ruling: physical-device Gate A,60/120Hz comfort/frame pacing/memory/performance — no measured acceptance; retain Gate A and explicit new-build evidence before later group — cost if wrong: unmeasured interaction regressions/device calibration rework.
- Ruling: real hardware-keyboard/IME window/VoiceOver/Switch Control/Reduce Motion usability — reviewed guarded code and simulator tests support implementation only; device acceptance pending — cost if wrong: inaccessible/uncomfortable input requiring native-device correction.
- Ruling: final light-mode/ink/highlights/visual calibration — prototype background/crop ships this slice, later formal visual scope remains open — cost if wrong: visual redesign/calibration without changing business owners.
- Ruling: catalog summaries/preview virtualization/session-switch retention/Router replay — not advertised as S5-03 delivered; S5-04 serial dependency owns real history/navigation — cost if wrong: premature navigation loses configuration/reading or over-retains full controllers.
- Ruling: browse/snap/creation/Soul binding/delete/Undo/Split/Sidebar/Search/Files/Settings — excluded from S5-03 and assigned ordered later slices — cost if wrong: incomplete Stage5 user journey, stage remains open.
- Ruling: cross-process Draft/reading restoration — only warm same-host return guaranteed, no new Draft/anchor schema — cost if wrong: terminated-process edits/position unavailable until separately specified.
- Ruling: alternative queued IME navigation — refuse current gesture/preserve candidate input, require fresh gesture; no replay — cost if wrong: entry-policy orchestration revision, no current input discard.
- Ruling: root cause historical immediateChinese-value failure — preserve intermittent unattributed observation and diagnostic, no repair claim — cost if wrong: underlying flaky input/test timing remains to investigate on evidence.
- Ruling: reviewer did not independently rerun macOS CI — independent static read-only review relies on exactHEAD realCI logs, Windows lacks Swift; full post-fix CI and main CI still required — cost if wrong: CI provenance/host-only blind spot, no device claim.
