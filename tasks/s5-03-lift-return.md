# S5-03 — continuous Surface Lift / Return

Work in progress; contract: [implementation plan](../Docs/Plans/2026-09-28-s5-03-lift-return.md).
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
- Latest head/implementation verification: [PR #18](https://github.com/54zhien/Zen-Agent/pull/18).
  Task1 GREEN pending; Task2 actual Composer/Surface integration and real gesture/host
  UI tests still pending. No integration or working Lift claim from pure tests.

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

Full implementation CI and independent whole-branch review are pending. The UI
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
