# Stage 8 Skills and Environment evidence

Status: implementation and native verification in progress. No completion,
merge, package delivery or physical-device acceptance is claimed by this record.

Base: Stage 7 receipt `f335204b387e9a5ca10fa2091dbb24e4e3368296`, on
`codex/stage8-skills-environment-20261024`. Stage 7 PR #42 remains separately
draft/unmerged; Stage 8 does not merge it or enter Stage 9.

## Approved intent and implementation boundaries

The owner approved native Settings Forms for Skills and Environment, next-commit
manual selection owned by the Conversation draft, and Global defaults overridden
only by the active Skill's declared keys. The design decisions are recorded in
[Blueprint draft PR #8](https://github.com/54zhien/Zen-Agent-Blueprint/pull/8),
head `e17d65eb1a1e037cb9e4d80ec4208dcbea582fb1`, stacked on Blueprint PR #7.
This is design authorization, not native acceptance.

Environment and Skill revisions are immutable; Send atomically associates exact,
content-free references with the original Run. Ordinary edits preserve its
versions. Explicit deletion or disable revokes first, settles the original owner,
then removes data and retires owned credentials. Failed settlement or cleanup is
visible and retryable. Recovery preserves existing file-operation proof and never
replays a dispatched write.

Only a relevant bounded subset of enabled Skills enters a request; explicit
selection takes precedence over the local router. Workflow text is untrusted
user context and cannot grant Tool permissions, increase exposure, or bypass
policy/approval. Scoped plain interpolation is bounded and rejects unknown keys,
cycles and Secret interpolation. Secret bytes are available only to trusted
credential/validation/execution seams; snapshots contain opaque references.

## Native development evidence

Focused diagnostic children change only the workflow selector and skip Pad;
their App, Tests, resources, configuration and project inputs match their stated
source commit. They are not the original full Phone/Pad gate. Failed runs remain
available under their original refs; no unchanged rerun is used as correction.

| Native run | Source | Actual conclusion |
|---|---|---|
| [39988029803](https://github.com/54zhien/Zen-Agent/actions/runs/39988029803) | `d6fbfe7` | App/XcodeGen passed; 1,276 Swift tests, 203 suites, intentional Environment schema/service RED 9; 20 XCTest passed. |
| [39990383415](https://github.com/54zhien/Zen-Agent/actions/runs/39990383415) | `be08634` | App passed; 1,277 Swift tests, intentional orphan-cleanup RED 2 plus existing streaming-fixture failure 1. Original Environment cases passed. |
| [39990785863](https://github.com/54zhien/Zen-Agent/actions/runs/39990785863) | `426565a` | App passed; 1,281 Swift tests, intentional orphan/schema RED 6 only. |
| [39991419430](https://github.com/54zhien/Zen-Agent/actions/runs/39991419430) | `3f2ca54` | App/test compilation passed; 1,285 Swift tests, intentional orphan/schema/Skill-service RED 10. Both actual management UI entries RED. |
| [39994385716](https://github.com/54zhien/Zen-Agent/actions/runs/39994385716) | `9b3284b` | App/test compilation passed; 23 Swift tests in 6 suites, behavioral RED 11 across draft consumption, actual Send, payload conflict and cold original-owner recovery. |
| [39995345439](https://github.com/54zhien/Zen-Agent/actions/runs/39995345439) | `3a8e24c` | App/test compilation passed; 22 Swift tests in 6 suites, Environment/orphan/scoped resolver/Skill lifecycle/snapshot/real-socket streaming GREEN. One authority test had an incorrect successful-Run expectation; its security assertions already passed. |
| [39996964522](https://github.com/54zhien/Zen-Agent/actions/runs/39996964522) | `c1d4e28` | App/test compilation passed; 35 Swift tests in 9 suites GREEN, including draft selection, actual requests, payload conflict and cold Skill/file-proof settlement. |

The streaming failure used the pre-existing small-open-body URLProtocol fixture;
existing characterization tests already show that fixture can withhold the first
small chunk. Only the affected test now uses the characterized local HTTP socket
with the same 400 ms liveness limit, 200 ms progress limit and assertion. No
production transport timeout was widened. The failed run remains evidence.

Test compilation failures are distinct from behavioral RED: `39992789922`,
`39993262190`, `39993364732` hit Swift Testing throwing lookup macro expansion;
`39994836997` used equality on a non-Equatable settings DTO. Corrections evaluate
throwing lookups separately and compare stable grant IDs. `39997664130` contains
two later throwing-constructor test errors; the corrected source is `bde5cf9`.
None is represented as a passing or executed behavioral test.

Completed logs, hashes, diagnostic/source identities and native artifacts are
retained in the ignored Stage 8 evidence directory and in GitHub Actions.
The frozen-Send GREEN log SHA256 is
`4738FD26E670A9FBF24F3C70DC74D4712AB92C60D80DFB570DD2CAB9384AF029`.

## Rulings and costs

- Stage 8 ships real Keychain storage, versioned bindings and a trusted resolver.
  Existing tools have no authenticated Secret input; MCP belongs to Stage 9.
  Cost: saved Secrets have no authenticated production action yet, disclosed in
  Settings. No fake secret-consuming executor is introduced.
- Ordinary Secret edits use fresh opaque references. Cost: retained historical
  bindings need lifecycle cleanup; explicit erasure remains stronger than replay.
- Scope and key are immutable identity. Cost: rename/move uses explicit
  dependency-aware delete/add rather than changing frozen reference meaning.
- Revocation and final removal straddle original-owner settlement outside the
  shared gate. Cost: failed settlement/Keychain retirement requires visible retry.
- New snapshots use v2; new builds read legacy v1 without Skills. Cost: old builds
  must reject v2 rather than silently resume a Run without its Skill semantics.
- Built-ins and copied definitions are disabled until explicitly enabled. Cost:
  one enable action; installation alone does not inject all workflows.
- Bounded UI work was delegated only after actual native management-entry RED;
  core wiring, source commits and verification remained with the owner agent.
  Pure contract work during CI waits was provisional until native tests ran.

## Remaining gate

Complete the Composer selector, inspect actual native UI captures, verify live
and queued erasure/Secret results/frozen exposure, conduct the one independent
whole-branch review and corrective pass, and run the unchanged complete source
Phone/Pad workflow. Record final source/tree and receipt-only input equivalence
before claiming the implementation/native gate complete. Physical-device UI,
Keychain/data-protection behavior and user experience remain separate acceptance.
