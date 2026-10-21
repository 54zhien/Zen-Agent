# UI integration test alignment — 2026-10-21

The owner finalized the current UI, authorized test-only adaptation and diagnosis,
and requested direct merge after a passing gate, followed by S6. Product UI must
remain unchanged; any required product correction stops for an impact explanation.

## Frozen product and original evidence

- UI baseline: `eb39a65d98116fbd53dccd6ba43cd9e685e8151d`;
  tree `f811529a766980a1f22b0bbccf87e2a0e5f89d79`.
- Integration PR: https://github.com/54zhien/Zen-Agent/pull/37.
- Original full run: https://github.com/54zhien/Zen-Agent/actions/runs/39619632065.
  Hygiene, generation, actual build, all 1,140 Swift Testing cases / 171 suites,
  20 XCTest unit cases and the actual iPad axis case passed. Native Phone failures
  are real assertion evidence; the whole run is not a passing gate. The final
  workflow conclusion is `cancelled`: the Phone job exceeded its configured
  65-minute limit. Phone did not produce a complete test summary, so no complete
  Phone totals are asserted. The preceding assertion failures remain RED.
- No unchanged retry or cancellation is used to replace that evidence.

## Test ownership and changes

- Sidebar setup explicitly verifies the first edge swipe dismisses raised input
  without opening Sidebar, then uses a separate edge swipe to open it. Search,
  Files and Settings use that setup. Keyboard-free cases retain a single opening
  gesture. A raised-sheet case also preserves editor identity and draft.
- Sidebar readiness includes native animation settlement and actual control
  hittability. A failure retains the native receipt; it is not hidden by another
  gesture, an arbitrary sleep, or a larger timeout.
  First-swipe dismissal also waits for the native closed/settled receipt when
  available, so transient AX absence cannot be mistaken for completed dismissal.
- Thinking tests and App Space geometry are being aligned to the current controls
  and the recorded centered-stack ruling. Split reading/AX failures require
  independent attribution, not relaxed reading-position assertions.
- Manual `ui-integration` CI selects the affected native UI regressions only.
  It is diagnostic verification, not the final full gate; ordinary full selection
  remains intact. No product test fixture, App source, resource, build setting,
  dependency, generated project, animation or UI behavior is changed.

Native verification of the adaptations, final source SHA/tree, full-gate outcome
and merge receipt remain pending. S6 implementation starts only after UI merge.

Focused runs on `e91095da3adbe5aa7686b77ef09826a2b1c75e7e`:

- Lift and unchanged Split reading assertions:
  https://github.com/54zhien/Zen-Agent/actions/runs/39630293867.
- Affected UI integration regressions:
  https://github.com/54zhien/Zen-Agent/actions/runs/39630300120.

These runs do not include the subsequent first-swipe native closed/settled wait.
Their results cannot validate that later change or replace the final full gate.
