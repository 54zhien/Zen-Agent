# S6-01 — Tool Policy pure rule kernel

This record belongs only to the isolated S6-01 branch. Stage 5 closure remains
with its original worktree. Stage 5 and Stage 6 are not declared closed here.

## Provenance and ownership

- Worktree: `C:/Users/Azusa/.codex/worktrees/8b9b/Zen-Agent`.
- Branch: `codex/s6-01-tool-policy`; remote: `54zhien/Zen-Agent`.
- Fixed base: `0c1122592b4112f136063e228c5d3376a8707853`.
- Base tree: `29ef04ccaf94cbbd439fce4d0f87860b0a11b740`.
- This managed worktree initially had detached HEAD `eec3eb3`; its clean checkout
  was moved to a new branch at the authorized fixed base. The S5 worktree's HEAD,
  branch, index and files were not modified.
- Blueprint spec: `3b4b22c0df91be668406127c84c1822b359883c0`, matching the fixed
  checkout's README. Tool Runtime blob: `9d961dc500d8b39bf1623e568becf347cf5239c7`.
- Source plan: [the branch's plan](../Docs/superpowers/plans/2026-10-07-stage6-policy-foundation.md).

## Allowed files

All changes relative to the fixed base are restricted to:

1. `App/Tool/Policy/ToolPolicyTypes.swift`
2. `App/Tool/Policy/ToolGrantScopeMatcher.swift`
3. `App/Tool/Policy/ToolPolicyEvaluator.swift`
4. `Tests/ZenAgentTests/ToolPolicyScopeTests.swift`
5. `Tests/ZenAgentTests/ToolPolicyEvaluatorTests.swift`
6. `Tests/ZenAgentTests/ToolPolicyTemporalTests.swift`
7. `Docs/superpowers/plans/2026-10-07-stage6-policy-foundation.md`
8. `tasks/s6-01-tool-policy.md`

The existing Registry, Runtime, built-ins, persistence, App shell, UI, Files,
Settings, Config, Resources, project.yml, workflows and shared handoff/todo stay
outside this branch's changes. The generated project collects the added files
through the existing App and unit-test directory sources.

## Evidence already observed

| Group | Exact source | Native evidence | Whole workflow |
| --- | --- | --- | --- |
| Fixed baseline | `0c112259` / tree `29ef04cc` | [37619427383](https://github.com/54zhien/Zen-Agent/actions/runs/37619427383): XcodeGen/build, 965 Swift tests / 156 suites and 20 XCTest passed; phone 58 tests, one expected Pad-only skip, three assertions in `WorkspaceRotationUITests.testLandscapeEditsBelongToTheLastActivePaneAndPortraitRestoresBoth` failed; actual Pad passed | failure |
| Scope RED | `17bcd251` / tree `7a780ba2` | [37622815846](https://github.com/54zhien/Zen-Agent/actions/runs/37622815846), job112797136062: completed Swift run 979 tests /157 suites with five issues: sameExactScopeMatches, scopeLessOnlyMatchesExplicitNoRequirements, exactTargetScopeMatches, onceMatchesOnlyItsFrozenCall, conversationGrantCanMatchLaterCallInSameExactScope. Conservative false versus required true; all other units and 20 XCTest passed | subsequently cancelled during UI; never GREEN |
| Scope GREEN | `57a8c718` / tree `54c2a412` | [37630609897](https://github.com/54zhien/Zen-Agent/actions/runs/37630609897), job112823653096: all 14 Scope functions and all 979 Swift tests /157 suites plus20 XCTest passed. Phone58 /one expected skip /three assertions in `PreviewHandoffUITests.testDeepReadingAnchorRestoresAfterNativeContentRemount` failed; actual Pad passed | failure; distinct S5-owned UI failure preserved |
| Evaluator pre-RED signature candidate | `df4ece2a` / tree `0afc7e5b` | [37638040685](https://github.com/54zhien/Zen-Agent/actions/runs/37638040685) superseded by explicit `return switch` correction; not behavioral evidence | cancelled; neither RED nor GREEN |
| Evaluator RED | `fe637c59` / tree `53de63f9` | [37638196089](https://github.com/54zhien/Zen-Agent/actions/runs/37638196089), job112850790372: compiled;20 new evaluator functions generated53 assertion issues, Swift999 /158 suites failed53 issues, all14 Scope and965 inherited Swift functions plus20 XCTest passed. Phone58 /one expected skip /zero failures; actual Pad passed | expected assertion failure |
| Evaluator GREEN | `3fd4b758` / tree `46976fdf` | [37643333096](https://github.com/54zhien/Zen-Agent/actions/runs/37643333096), job112867687720: XcodeGen/build,999 Swift /158 suites,20 XCTest, phone58 /one expected Pad-only skip /zero failures, actual Pad and hygiene passed | success |
| Temporal/identity RED | `a49f5d62` / tree `b8b26987` | [37649932736](https://github.com/54zhien/Zen-Agent/actions/runs/37649932736), job112890393623: compiled;1019 Swift /159 suites failed45 issues,26 across13 encoded-identity and13 blank-identity cases,19 temporal issues across11 functions. Prior evaluator and inherited units passed;20 XCTest and phone58 /one expected skip /zero failures, actual Pad passed | expected assertion failure |
| All rules GREEN | `dadabd8b1f38b377c26c117a9f7648ad1a9ab45a` / tree `dc1a9a1a381e8630b4efafde1c84b642b6e865c1` | [37656163959](https://github.com/54zhien/Zen-Agent/actions/runs/37656163959), job112911658848: XcodeGen/build,1019 Swift /159 suites (54 added Policy functions),20 XCTest, phone58 /one expected Pad-only skip /zero failures, actual Pad and hygiene passed | success |

Each observed unit run above had one actual Swift Testing run start. A cancelled
workflow is not passed; completed rule assertions before a later cancellation
are recorded as assertions only. No compiler failure is labeled behavioral RED.
The superseded candidate has no RED/GREEN claim.

All three rule groups now have actual RED/GREEN evidence. The all-rules source
run had one Swift Testing start, zero host restart, and no retry. The phone-only
Pad skip is recorded separately; the actual Pad job executed successfully.
The final handoff documentation commit still requires its own exact-head CI;
the conversation's final receipt identifies that SHA/tree without a self-SHA loop.

## Rule boundary and future integration

The input is trusted, read-only authorization facts projected from the existing
ToolCall and immutable ToolExecutionIntent. It has no arguments JSON, executor
payload, alternate call state or storage. Descriptor metadata, actual resolved
resource/destination and the intent binding must come from trusted Runtime code,
not model arguments or the pane displaying approval.

One complete grant must cover the entire subject, action, revision and exact
source/destination; separate grants never combine into a source-to-sink permit.
The decision has stable reason codes. An allow result is a point-in-time
calculation, never a cached execution license.

Creation policy/admission and current policy remain distinct. Automatic
admission only survives unchanged binding and revocation epoch; widening does
not release an old waiting/denied call. Repreparation must not inherit an old
intent's admission. Matching fresh once approval, or a permitted conversation
approval explicitly issued for this call/run/intent, can authorize that call.
Another call's new conversation grant only serves legitimately admitted future
calls. Inactive/revoked/consumed grants, ended subjects and unavailable calls do
not authorize execution.

The trusted future layer supplies call/subject eligibility, approval origin and
the relevant monotonically increasing revocation epoch. The epoch must reflect
applicable policy, cap and grant tightening, remain coherent across revalidation,
and never fall when Settings widens. The kernel neither tracks these events nor
stores their state. Current resolved dependencies are compared to the frozen
intent before grants; no old approval can substitute a new version/destination.

Opaque identities compare UTF-8 bytes, with no normalization or resolver. Swift
text equality uses canonical Unicode equivalence ([primary documentation](https://docs.swift.org/swift-book/LanguageGuide/StringsAndCharacters.html));
the13-axis native RED reproduced that widening before the byte comparison fix.
Whitespace-only identity tokens are invalid; explicit no-resource requirements
remain different from missing required identity.

Production dispatch, grant/policy persistence, OS consent/permissions, Files
Tool and Settings remain unimplemented here. No dependency, capability,
entitlement, signing or IPA change is part of S6-01. Future integration must
revalidate before the existing dispatch marker and preserve its crash semantics.

## Execution rulings

- PowerShell ledger/manual task briefs adapt the skill's Bash bookkeeping to this
  Windows checkout; cost: bookkeeping is manually maintained.
- S5-owned UI failures are preserved separately from completed Policy rule
  results; cost: these rule results do not establish a clean cumulative full gate.
- Completed unit assertion failures before later UI cancellation establish RED
  only; cost: they never establish a passed workflow or GREEN gate.
- Opaque byte identities, immutable admission binding and relevant revocation
  facts make authority changes explicit; cost: future Runtime/Persistence must
  supply coherent resolved identities, eligibility, origins and monotonic epochs.

## Review and stop status

One independent whole-branch read-only review completed for the tested source
`dadabd8b`. It inspected the base-to-head diff, supplied plan/spec and uncommitted
handoff refresh, and independently checked the real CI. No Critical or Important
finding; one Minor is deferred. The reviewer modified no file, index or HEAD.

**Deferred P3:** synthesized whole-value `Equatable` on some identity-carrying
DTOs (including `ToolGrantKind.once`, call/grant/admission/policy/input values)
can consider differently encoded text equal, whereas the authorization matcher
correctly distinguishes UTF-8 bytes. Current evaluator never uses whole-input
equality to grant permission, so no authorization bypass was found. Remove
unneeded conformance or align it to byte semantics before a future consumer
relies on equality. No production code was changed for this Minor in this pass.

Review exclusions were explicitly resolved, not silently counted as verified:

| Considered behavior | Resolution | Cost / remaining validation |
| --- | --- | --- |
| Trusted Runtime/frozen-intent projection | Explicitly outside S6-01 | Must be implemented and tested at integration |
| Admission creation, persistence/recovery and immutability | Consume facts only | Owning layer must preserve actual authority history |
| Atomic epoch updates on revocation/cap/policy tightening | No event/store implementation | Future owner must update coherent monotonic facts atomically |
| Approval origin, subject lifetime and terminal eligibility provenance | Trusted inputs, not UI inference | Future authoritative storage projection must be tested |
| Pre-dispatch revocation race, grant consumption, recovery/replay | Existing execution chain untouched | S6-04 still needs conditional/serialized dispatch validation |
| OS consent, managed Files, result guard, Settings, MCP/Child delegation | User/plan excludes implementation | No live capability or integration claim |
| Multiple resources/targets, wildcard and expiry clock | Only declared single exact scopes | No set/wildcard/time permission support |
| Forbidden conversation grant alongside independent alwaysAllow | Conservative needsApproval follows allowed-choice constraint | May ask instead of silently substituting another grant kind |
| Explicit-approval cap with a legal conversation grant | Honor independent allowsConversationGrant declaration | Per-call-only confirmation must explicitly prohibit conversation grants |
| Nonblank token syntax, URL normalization and actual identity resolution | Consume opaque trusted identities only | Resolver/format authenticity needs separate integration checks |
| Simulator CI vs device/Stage5/full Stage6 closure | Keep distinct | No physical-device or stage-closure claim |
| Final documentation SHA/tree CI | Separate final exact-head gate | Final receipt comes from completed CI, not earlier source run |

No design conflict or irreversible storage decision was discovered; no ADR or
Blueprint rewrite is introduced just to mirror code. Local static checks include
YAML/source paths, existing profile `full`, its12 Python regressions, complete
tracked/untracked file review and `git diff --check`; native results above are CI,
not claimed local Windows Swift builds or physical-device acceptance. Raw
execution logs/receipts and the review report are retained outside this checkout
at `C:/Users/Azusa/Documents/Codex/s6-01-policy-evidence-20261008-8b9b`.

The documentation refresh changes only this independent record relative to the
tested code head. The final exact HEAD/tree and CI are supplied in the final
conversation handoff; this avoids inventing a self-referential commit SHA here.

Stop after S6-01. No S6-02, PR merge, main push, automatic S5 absorption or IPA.

## Authorized fixed Stage 5 baseline sync — 2026-10-09

The owner explicitly authorized the original S5 executor to deliver a verified
fixed main baseline to this original S6 worktree for sync and combined full CI.
That authorization permits this one baseline absorption, not S6-02 or a S6-to-main
merge. The original S5 worktree remains separately owned and was not modified.

- Pre-sync checkpoint H: `47ee7ed9c47603f15079d78f02a3599c11b68e50`.
- H tree: `1435e0de48d41aae541949389ee770daf07697a8`.
- Fixed M: `52a456bb53d10360aa6d485202f4bd05e2c6bdbf`.
- M tree: `3653f870c941368ff4fa4e6abc89e854a55cf2db`.
- M parents: `eec3eb38c3d4869a58031449f303f04dec55d0fd` and
  `e9b808ee24fcfaf5de289b1567a51f749f071fd4`; actual ordinary merged PR35.
- [M's own full CI37918132167](https://github.com/54zhien/Zen-Agent/actions/runs/37918132167)
  completed success at exact M: hygiene, XcodeGen/build,987 Swift /158 suites,
  20 XCTest, phone61 /one expected Pad-only skip /zero failures, actualPad1 /zero
  failures /zero skips. Raw logs independently verified: one Swift run start,
  zero host restart; source-run results never substitute for combination CI.
- M phone log SHA-256:
  `43eaff47b1a7281edc11644ce384886c630ba7e50b54e491a109ad24c949c851`.
- M Pad log SHA-256:
  `7226d876a5e04dfe53c667b09c8c6926775742a3ba97ef8608bd871aa6d506e2`.

The live named S6 worktree, index and nonignored untracked state were clean at H.
No stash, reset, forced commit or cleanup was used. A normal
`git merge --no-ff --no-commit` consumed this fixed M, not floating main, then
paused for actual index review. There was no text conflict or whitespace error.

Relative to M, the combination contributes only the same eight authorized S6
paths above. Before this record update, all eight S6 file blobs and literal
working-tree SHA-256 values matched H. The six Policy sources/tests remain
byte-for-byte H content after this documentation update. The S6 plan is also
unchanged. Relative to H, imported non-S6 paths come directly from verified M;
this executor made no S5 production/test modification or blanket conflict choice.
The original focus regression/parameters/assertions are kept at M's exact blob.

This ordinary merge commit is combination N, with parents H and fixed M. Its
exact SHA/tree, two-ancestor checks and N-specific complete CI receipt are reported
by the final conversation handoff and archived evidence, avoiding a self-SHA loop.
The N CI must execute the existing full profile including phone, actual Pad and
hygiene; previous counts are historical observations, not hardcoded acceptance
counts. A failed, cancelled or incomplete N run is not passed. No focus-only
diagnostic or unchanged retry sweep is authorized by this sync.

### Known deferred/open items retained from M

- **The intermittent incoming Composer stable-focus loss is not fixed.** The
  owner exhausted the two additional original false/true diagnostic attempts,
  `37907105288` attempts2/3 (3.518s/4.016s), then explicitly deferred the issue to
  continue engineering sync. Both passed without a B-loss event, so no initiating
  cause or repair is inferred. Historical RED37784846258 and37801912044 remain
  valid unresolved evidence. Temporary probes were removed; original regression
  assertions stay enabled. No new focus investigation or retry is added here.
- Historical iPad first-Sidebar failure remains disclosed. Current green CI does
  not erase that history or establish physical-device acceptance.
- Physical-device acceptance and SQLite teardown warnings remain open; no broad
  cleanup/refactor is part of baseline sync.
- The S6 whole-DTO `Equatable` P3 remains deferred as documented above. This
  mechanical sync does not change Policy code; address equality separately before
  a future consumer relies on it.
- Production Policy/intent/dispatch integration, persistence, system permission,
  Files, Settings and all S6-02 onward work remain excluded. Engineering sync is
  not an announcement that all Stage5 or Stage6 acceptance is complete.

Stop after combination verification. No S6 PR merge, main push, IPA or S6-02.
