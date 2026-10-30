# Stage 10: Serial Subagent delegation

**Status:** The Stage 10 serial delegation slice passed its exact-head native PR gate on `cee3bdf2c74655b565ee71393feb6d0f0272d7f5`. This closes validation for this implementation slice only; it is not a Stage 10 closure.

- PR: [#47, Stage 10: serial Subagent delegation](https://github.com/54zhien/Zen-Agent/pull/47), draft/open
- Branch: `codex/stage10-delegation-snapshot`
- Base: PR #46 branch `codex/stage9-mcp-completion` at `bb7022859be5ea6dd8debd12f4033becfbab13fb`
- Current source candidate: `cee3bdf2c74655b565ee71393feb6d0f0272d7f5`
- Previous test-failing candidate: `8fcb92d264c3a2563f3b5b18d5c7f273949d2e31`
- Worktree: `C:\Users\Azusa\.codex\worktrees\stage10-delegation-snapshot\Zen-Agent`
- Product decision record: [Blueprint PR #9](https://github.com/54zhien/Zen-Agent-Blueprint/pull/9), owner-decision commit `f8861dd9c98a416cdf80ab1ccb8d576a183a6ee2`

## Implemented slice

- A persisted global delegation policy has a real runtime consumer. Parent preparation reads it once and freezes the resulting revision into the Parent execution snapshot.
- The frozen policy is off by default. When enabled, it uses Follow Parent semantics, depth 1, one serial active Child, and an empty Environment mapping. Spawn consumes the Parent snapshot rather than rereading mutable settings.
- The callable Subagent path creates one independently persisted Child Run, linked to the original Parent ToolCall identity. A terminal Child result is durably confirmed back through that ToolCall; Child messages do not become Parent conversation history.
- Stop, dependency invalidation, and cold recovery reconcile linked Child state before settling the Parent. Known terminal outcomes are reused by stable identity. A dispatched call with unknown provider outcome is not replayed or marked `notExecuted`; undispatched delegation calls receive an explicit terminal result.
- Child dispatch is limited to the Parent's frozen provider/model semantics. Child snapshots do not carry recursive delegation, tools, MCP dependencies, Memory, Skills, Soul, or Environment values.

## Explicit boundaries

This slice does not add Settings UI, multiple Children, parallel execution, recursive delegation, Child Tools or Child approval grants, configurable Environment mappings, or inheritance of Memory, Skills, Soul, or Environment. A Child does not receive a Tool-authorization capability in this slice; the Parent's Subagent invocation remains subject to the shared ToolPolicy. These are not claimed as completed Stage 10 work.

No merge or physical-device acceptance is included. The draft PR remains stacked on the unmerged PR #46 branch.

## Current native validation

The exact-head PR event is [run 40990023248](https://github.com/54zhien/Zen-Agent/actions/runs/40990023248) on source SHA `cee3bdf2c74655b565ee71393feb6d0f0272d7f5`. It completed successfully: repository hygiene, XcodeGen generation, app build, XCTest, Swift Testing, Phone UI, and the independent iPad axis all passed. The `Run app unit and UI tests` step ran from 02:12:31 to 03:21:03 UTC (68m32s); the Build and test job completed at 03:21:46 UTC.

| Exact-head validation | Result |
|---|---|
| Repo hygiene | Passed. |
| XcodeGen generation and app build | Passed. |
| XCTest target | 20 tests, 0 failures. |
| Swift Testing | 1,340 tests in 227 suites passed after 164.157 seconds, with no reported issues. |
| Phone UI target | 98 tests, 1 expected Pad-only skip, 0 failures. |
| Independent iPad workspace axis | `WorkspacePadAxisUITests.testNativeAxisMenuPreservesBothEditorsAndSeparateRatios` passed (113.605 seconds). |
| Guard self-test | [Run 40990023259](https://github.com/54zhien/Zen-Agent/actions/runs/40990023259) passed. |

The Stage 10 delegation runtime suite passed all four behavior tests (0.240 seconds): `parentDelegatesAndContinuesFromChildResult` (0.098s), `delegationDefaultsDisabled` (0.035s), `coldStartStopSettlesUndispatchedDelegation` (0.041s), and `parentInvalidationSettlesActiveChild` (0.063s).

The `Tool approval UI red probes` Swift Testing suite passed in 1.226 seconds. These four previously failing cases each passed: `waitingForApprovalShowsCardInOwningConversation` (0.104s), `approveResumesSameToolCallViaExecuteApproved` (0.221s), `rejectPersistsTerminalResultAndContinuesModel` (0.172s), and `staleApprovalCannotResolveAnotherConversationCall` (0.172s). These results are from Swift Testing log output; they are not Phone UI test results.

The changed Swift files also pass Windows Swift frontend parse and `git diff --check`; these local checks supplement but do not replace the native CI evidence.

The same SHA also triggered push run [40990018485](https://github.com/54zhien/Zen-Agent/actions/runs/40990018485). Hygiene, app build, and iPad axis had passed, with no failure recorded before its unit/UI step was cancelled as redundant. Cancellation is not a passing result; the PR-event run above is the sole full-gate evidence.

## Preserved native RED on the previous candidate

The prior PR event is [run 40981534471](https://github.com/54zhien/Zen-Agent/actions/runs/40981534471) on exact source SHA `8fcb92d264c3a2563f3b5b18d5c7f273949d2e31`.

| Job / step | Evidence at this update |
|---|---|
| Repo hygiene (`123822791814`) | Passed. |
| XcodeGen generation / managed build settings | Passed. |
| Build app | Passed. |
| Swift Testing (`123822848570`) | Failed: 1,340 tests in 227 suites, 18 issues. Three issue reports came from this slice's two tests; 15 came from four `ToolApprovalUITests` cases. |
| XCTest target | 20 tests, zero failures. |
| Phone UI target | 98 tests, one expected Pad-only skip, zero failures. |
| Independent iPad workspace axis (`123822848629`) | Passed. |
| Guard self-test (`40981534358`) | Passed. |

The first exact-source run exposed two slice-local test setup/expectation defects. The environment assertion compared optional `nil` to the enum case; `cee3bdf` now names `DelegationEnvironmentInheritance.none` explicitly. The invalidation fixture used `Fixtures.run`'s unprovisioned `cred-1` while its credential store only provisioned `credential-i05`; the real `SecretContentGuard` therefore withheld the terminal Child report as `.redactionUnavailable`. `cee3bdf` aligns the Parent fixture to `credential-i05` generation 1; the `.executionFailed` and structured Child-report assertions remain intact. No production redaction behavior or expected result was changed.

The 15 `ToolApprovalUITests` issue reports were four existing cases receiving events for another Conversation's pending Run when `start()` initiated a process-wide scan through the current runtime callback. `cee3bdf` keeps app-launch global recovery, scopes a Send-triggered scan to its command Conversation when no global scan is in flight, and single-flights recovery by Conversation. A global scan registers its barrier before awaiting existing scoped tasks, merges their reports, then scans the remaining Conversations. A later Send after global completion scopes again instead of treating the old global completion as coverage for every Conversation. The four tests' expectations and fixtures are unchanged.

On Windows, the changed Swift files passed frontend parse only. There is no local Xcode build or iOS test result; the native CI run is the compilation and behavior evidence.

## Preserved compiler failure and cancellation provenance

The first PR candidate `9e3c2b637274b908f94012dd4de09a18f60e034f` had a real compile failure in PR run [40980867764](https://github.com/54zhien/Zen-Agent/actions/runs/40980867764), Build and test job `123820362093`:

- `Migrations+Delegation.swift:19`: the GRDB `primaryKey` call required a field array.
- `PersistenceStore+Delegation.swift:180`: the `database.read` result was not returned, leaving `nil` without an optional contextual type.

The app build failed, so unit/UI tests were skipped; this was not a behavioral test failure. The follow-up commit corrected those compile errors and returned the confirmation write result. The old run's iPad job `123820362159` was later cancelled after its build failure had been retained; the overall run is therefore cancelled while its Build and test job remains a recorded failure.

Same-SHA duplicate push run [40981529090](https://github.com/54zhien/Zen-Agent/actions/runs/40981529090) was cancelled to leave the PR-event run as the full-gate candidate: hygiene passed, Build and test was cancelled before compilation, and the iPad job was cancelled. It is neither a successful gate nor a build failure.

## Closeout boundary

`cee3bdf` contains the scoped-recovery production fix and only the two test setup/expectation corrections. The PR #47 exact-head native event passed as recorded above. PR #47 remains draft and unmerged, stacked on unmerged PR #46. Child Tools/approval, configurable Environment mappings, Settings UI, remaining Stage 10 work, and physical-device acceptance are not included or claimed. No merge or downstream-stage authorization is implied.
