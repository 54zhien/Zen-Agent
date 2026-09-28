# S5-04 preview virtualization — implementation gate

Base aeaa05cd7ce6c1e41329da629ed6bdfc54b6e7a5; main CI36401064255 passed
generation/build,689 Swift Testing/108 suites,20 XCTest unit and11UI tests.
Blueprint baseline596a84d4b58769e3e7b838be95edcb43f9e0ec82 and supplied Stage5
plan define intent; [implementation plan](../Docs/Plans/2026-09-28-s5-04-preview-virtualization.md)
records ownership, failures, cancellation and file boundaries.

Current state: test-first Router/session regressions added using existing APIs;
production is unchanged, compiled behavior RED pending macOS CI. No S5-04
capability or device acceptance is claimed. Gate A remains open.

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
