# S5-04 preview virtualization — implementation gate

Base aeaa05cd7ce6c1e41329da629ed6bdfc54b6e7a5; main CI36401064255 passed
generation/build,689 Swift Testing/108 suites,20 XCTest unit and11UI tests.
Blueprint baseline596a84d4b58769e3e7b838be95edcb43f9e0ec82 and supplied Stage5
plan define intent; [implementation plan](../Docs/Plans/2026-09-28-s5-04-preview-virtualization.md)
records ownership, failures, cancellation and file boundaries.

Current state: Task1 owner/Router source resolves its first compiled regressions;
late-callback and terminal-Part fixes plus real Runtime remount probes await full
GREEN. Tasks2/3 and whole-branch review remain. Gate A remains open.

Initial regression contract: detached active Run releases its Full Pane and live
store without losing route; hidden tokens do not repaint an outgoing display;
real persisted A/B/A navigation retains Composer and reading owners, full Draft,
chosen configuration and anchor restoration while old Run seeds stay frozen.

First compiled behavior RED:8049f6977a97ff6a5f72155ab9c4b1b01fbc9587,
CI36403024476 attempt1/job108865195675. Generation/App build succeeded;
691 Swift Testing/108 suites failed10 issues confined to new warm-owner/configuration/
reading assertions, detached Pane release and hidden repaint.20 XCTest units and11UI
tests passed; one run start, no host restart. The initial weak-store reference pointed
to the pre-runAccepted store that had already been replaced: its passing assertion
is not live-store release evidence. Correct capture and real persisted text/reasoning
resume regressions are added before any production change; supplemental RED pending.

Supplemental compiled RED:3e55f43b31d2d34cd61da4f44de58402c348b25e,
CI36404813785 attempt1/job108870953816.692 Swift Testing/108 suites failed16
issues:8 warm owner/configuration/reading,2 actual Pane/live-store retention,
5 persisted reasoning provenance/resume/offset and1 hidden repaint. Text resume
control passed;20 XCTest units and11UI tests passed,one run start/no host restart.

First source candidate adds lightweight ConversationSession ownership, warm owner/
configuration/reading restoration, existing-history seed fallback and availability
validation; Router discards detached Panes/token queues and reconciles durable
history using active Part identity and terminal checkpoints; Timeline/live store
preserve reasoning sources. Runtime, schema and dependencies are unchanged.
This candidate deliberately retains old late-target-failure routing and the old
isCompleted-only terminal-Part classification while new existing-API regression
tests obtain their RED. No full GREEN/working claim yet.

Ruling: a visible End already consumed is not replayed as unread work at the next
mount. Invisible/recovery End retains a small checkpoint until durable reload.
Cost if wrong: unread/terminal projection reconciliation must be refined, not a
hidden full Pane or token queue restored. Completed routes release identity;
unregistered late old events use the existing bounded diagnostic path.

First source8314babe7120d0d6ea579d355447b393ac2b0945/tree860f19ac,
CI36407135420 attempt1/job108878518021: generation/App build succeeded;
694 Swift Testing/108 suites executed with7 issues, confined to the two new edges.
All previous16 failures passed: warm owners/config/reading, weak Pane/live-store,
hidden repaint and actual text/reasoning offset recovery. Late A failure disabled
B with matching target IDs (3 issues); failed/cancelled persisted Parts reopened
as streaming (4 issues). Completed control passed.20 XCTest and11UI passed;
one run start/no restart. This is compiled behavior RED, not a scaffolding failure.

Minimal fixes capture the conversation owner in the old bridge callback and update
only its matching session; keep actual Part state in the projection, resume only
pending/streaming, and preserve terminal state on live completion. Quote eligibility
still derives from completed only. Supplemental tests exercise real Runtime with a
file-backed1000-chunk detached stream, active remount, postmount output and reopened
database; detached completion/Stop; original-Runtime approval dedup and rejection.
No Runtime/schema/dependency changes. Full GREEN pending; not device acceptance.

Fix candidate b820521/CI36409143844 generated and built the App, but new approval
test omitted the required Pane coalescer argument (test compilation failure).
No behavioral outcome from that run is counted. Fixture argument repaired; the
compiled694-test/7-issue RED above remains the production regression evidence.

Task1 GREEN:1cac7b34e76e11e5a8a8425439cd25bd68a3215d,
tree5fa9df0f935138899a4ea6b25c3d522524300243; CI36409682592 attempt1,
build/test job108886742072 and hygiene108886675925 passed; Guard36409682620
passed.697 Swift Testing/108 suites passed in63.262s;20 XCTest units and11UI
passed (UI256.577s). One test run start/no restart. Real file-backed1000-chunk
Runtime/remount/reopen test passed11.057s, detached completion/Stop0.107s,
original-Runtime approval remount/reject0.047s; late-owner and terminal-Part cases
passed. This closes Task1 code evidence, not S5-04 or physical acceptance.

Task2 RED package uses existing Shell APIs with100/1000 real unnamed histories and
GRDB7.11.1 statement tracing: bounded50-row first page, fixed query budget, honest
read-error retention/publication and unchanged activity. New cursor/window/status
APIs have a minimal runnable scaffold because no prior API existed; it deliberately
retains whole-list reads, no cursor and incomplete status/data projections. Tests
cover complete keyset order, pinned/time/id ties, max4 caller-ordered previews,
extreme page limits, corrupt JSON/shape, provider/model provenance, text bounds and
the Blueprint status mapping. Compilation alone is not RED. Replace the temporary
scaffold only after actual behavioral failures; no capability/whole-branch claim yet.

Task2 initial RED: c0036e6708b79c1800a63d9485bc0433821c646d,
treef95259adc1c28901375b44dd01fb5eff54df19c9; CI36412015036 attempt1,
job108894244467: generation/build and test execution succeeded,706 Swift
Testing/110 suites failed43 issues.20 XCTest units and11UI passed; one run start,
no restart. Failures are bounded page/window/cursor/text/provenance/disclosure,
status mapping and Recent read retention/limit. Actual legacy Recent100/1000
histories returned100/1000 with301/3001 SELECTs (72.714/533.851ms); these are CI
fixture measurements, not device performance.

First Task2 source e0acad46d46f487ae91fe123413f8a308f14e131,
tree0cd601c5cba3abfc6a13cfed916f7d60c96b50a1: materialized bounded metadata
before text joins; keyset pinned/activity/id; latest Parent provenance; max4
caller-ordered window; guarded text JSON and bounded title/excerpt; explicit
business status mapping; bounded first Recent page preserves read errors.
CI36414414586 pending. New101-row pagination/retry and newer-Child exclusion
regressions added. More/retry methods deliberately remain inert until their own
compiled behavioral RED; this candidate is not delivered functionality.

User requested a stop after the current part: finish Task2 and its real CI,
then pause before Task3. S5-04 remains draft/unmerged until Task3 and its single
whole-branch review are complete. No physical acceptance or IPA claim.

Task2 first-source CI36414414586 attempt1/job108902042466:708 Swift Testing/
110 suites failed6 issues, all in the deliberately inert More/retry regression.
All initial43 issues passed, including Child exclusion.20 XCTest and11UI passed;
one run start/no restart. Actual Recent100/1000:50 returned,1 SELECT each,
2.285/2.342ms; rich summary100/1000:50 returned,1 SELECT,5.626/7.292ms.
Times are CI fixtures, not device performance. This authorizes the minimal
pagination/error retry source: retry the failed page using its retained cursor,
append unique identities, publish exhaustion, expose More/retry in existing Recent.
Corrupt summary content has an explicit row indicator. Full GREEN pending.
