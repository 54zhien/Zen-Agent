# Runtime multi-round tool cold recovery

**Date:** 2026-10-29

**Branch:** `codex/multi-round-tool-recovery-20261029`

**Base:** Stage 8 `codex/stage8-skills-environment-20261024` at `ed2e32c9cfc31c21e4ae3ed9b7cfc413b1094c8f`

## Scope

The Stage 6 closure already records that first-round-only cold transcript rebuilding
fails safely rather than dropping protocol history. This follow-up lets a cold
recovery reconstruct a later tool request when all prior tool rounds are complete.
It does not expand recovery for interrupted Provider attempts or incomplete tool
call suffixes.

## Implementation

- Migration v24 adds nullable `agentStep.protocolResponse`. After a completed
  Provider `.toolCalls` response and before Tool processing, Runtime stores the
  versioned assistant content and exact ordered Provider calls (IDs, indices,
  names and raw arguments). It does not copy the system prompt.
- The multi-step rebuilder reconstructs prior assistant-call and ToolResult
  messages from those transcripts and persisted results. The existing one-step
  reconstruction path remains available for legacy rows without transcripts.
- Multi-step recovery accepts only consecutive sequence numbers and attempt 1.
  Every batch must exactly match its persisted transcript; prior batches also
  require terminal calls and persisted results. Missing, reordered or extra
  suffix calls remain unrecoverable; recovery never silently omits them or
  replays prior calls. Latest-step execution-intent validation remains in place.
  Interrupted/retried attempts retain their existing recovery behavior.

## Regression and review evidence

- Test-only RED `c9b51e7b9275d8854b9dc7eb53088e15f0531821`,
  [CI run 40823419229](https://github.com/54zhien/Zen-Agent/actions/runs/40823419229):
  `AppColdStartRecoveryTests.laterToolBatchKeepsProtocolHistory` failed at the
  intended continuation assertion (`continuedRunIDs [] != [runID]`).
- Candidate `8489bb00d3fadf580be13311fa9194af5ca0d559`,
  [CI run 40832118705](https://github.com/54zhien/Zen-Agent/actions/runs/40832118705),
  was superseded and cancelled while Phone tests and the iPad regression were
  running. It has no full behavioral result and is not counted as RED or GREEN.
- Corrected implementation `779bd6b6156dc17ef8bd0b01a8b19298eb73abb7`,
  [CI run 40832564892](https://github.com/54zhien/Zen-Agent/actions/runs/40832564892):
  the target cold-recovery regression passed. The overall Phone suite had one
  observation failure in `ToolApprovalUITests.detachedApprovalRemountsOnce`:
  its helper polled persisted Run state before the routed `.waitingForApproval`
  event had completed. The bounded review's finding about historical rejected
  tool calls without an execution intent was corrected while preserving latest
  call validation.
- Test-only synchronization commit `9f6edea5563e963c0e5fd39999e898c013f131a3`
  replaces that helper's database polling with the existing event recorder's
  wait for the routed waiting-state event. The run ID, persisted Run state and
  ToolCall state assertions remain. No production code, test matrix, CI profile
  or timeout budget changed. Independent bounded review approved this final
  change.
- Final full [CI run 40841938463](https://github.com/54zhien/Zen-Agent/actions/runs/40841938463)
  passed on `9f6edea5563e963c0e5fd39999e898c013f131a3`:
  - Repo hygiene, XcodeGen generation and App build passed.
  - Phone Swift Testing: 1,318 tests in 221 suites passed; the target cold
    recovery regression passed in 0.304 seconds.
  - Phone XCTest unit: 20 tests passed. Phone UI: 97 tests, 96 passed, 1
    expected Pad-only skip, 0 failures.
  - Pad axis: 1 native test passed in 96.553 seconds, 0 failures.
  - The Phone log contained one actual Swift Testing run start; the workflow's
    restart guard passed, with no host restart evidence.

This is a code-level CI receipt, not physical-device acceptance. The branch is
stacked on Stage 8 and remains separate from `main`; Stage 9 has not started.
