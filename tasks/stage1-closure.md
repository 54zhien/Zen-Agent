# Stage 1 Closure

Status: CLOSED
Stage 1 implementation gate SHA: 1b7394b4545861b0645962dcf8bf4954aaa9279b
Blueprint Stage 1 baseline: 6b12e460a5db3fabaaff8f39b4732bcb73fb6405
FileAsset policy commit: ac765ab57554e16ae2abbe017ca80c21ef8bedfe

## 1. Scope

| Stage 1 item | Result |
|---|---|
| Conversation / Message / Part + Repository | CLOSED |
| AgentRun / AgentStep / ToolCall persistence skeleton | CLOSED |
| CredentialStore / Keychain boundary | CLOSED |
| Provider / ProviderInstance / Transport | CLOSED |
| DeepSeek adapter | CLOSED |
| Streaming event normalization | CLOSED |
| ModelDescriptor / capability | CLOSED |
| Minimal PromptComposer | CLOSED |
| FileAsset / FileAssetVersion / MessageAttachment logical boundary | CLOSED |

Stage 1 deliberately does not include the full AgentRuntime, RunProjection,
Stage 2 execution-snapshot semantics, ToolRuntime, Conversation UI, physical
FileAsset I/O, Soul, Memory, Skill, MCP or Subagent orchestration.

## 2. Pre-closure correctness fixes

Z-01 — Credential mutation serialization
- main SHA: `f5b25de`
- main CI: `35570877983` — success
- result: CLOSED

P5 / Z-03 — Provider diagnostic containment
- main SHA: `d15bb67`
- main CI: `35572069071` — success
- result: CLOSED

## 3. S1-01 — Provider streaming normalization

RED
- ref: `probe/s1-01-red`
- sha: `a68283a7f14eff08e0598886d28c39fbd3e9bc2d`
- run: `35569793575`
- classification: historical contract compile-red; not a clean assertion-red
- note: CI surfaced the missing `ProviderStreamEvent` production contract. The
  historical probe also contained an independent test-source argument-label
  defect, so it must not be represented as a clean assertion-red.

GREEN
- main SHA: `434d22a0d4167a834b781e429169c8f858b46538`
- branch CI: `35573362282` — success
- main CI: `35574046354` — success
- test-host restarts: 0

## 4. S1-02 — ModelDescriptor capability

RED
- ref: `probe/s1-02-red`
- sha: `af27cff97e980369c92b2033c6485dea07aa7b86`
- run: `35574678181`
- classification: clean contract compile-red
- reason: `ModelCapability` and `ModelDescriptor.capabilities` did not yet exist.

GREEN
- main SHA: `124e013095e1d6582e9b96ba9938dc9165a41e90`
- branch CI: `35574671820` — success
- main CI: `35576191770` — success
- test-host restarts: 0

## 5. S1-03 — Minimal PromptComposer

RED
- ref: `probe/s1-03-red`
- sha: `62da647ef2289264f8d5980834680e6fc7e61a70`
- run: `35577522536`
- classification: clean contract compile-red
- reason: the tests required the prepared prompt-composition contracts before
  those production types existed.

GREEN
- main SHA: `045bf2f29cf5db166e03aa29ce9c37363f3c6e51`
- branch CI: `35577517245` — success
- main CI: `35579119126` — success
- test-host restarts: 0

## 6. S1-04 — FileAsset logical identity boundary

RED
- ref: `probe/s1-04-red`
- sha: `c0967a011bf1d3606e2d8a6b6725bf32ad7b52fe`
- run: `35581114178`
- classification: clean contract compile-red
- reason: the tests required `FileAssetRecord`, `FileAssetVersionRecord` and
  `MessageAttachmentRecord` before those production contracts existed.

GREEN
- main SHA: `3dec9b465eaf19e08eef59e5f311f0b5b120f4db`
- branch CI: `35581110389` — success
- main CI: `35581988638` — success
- test-host restarts: 0

Proven invariants
- stable FileAsset identity is distinct from immutable version identity
- `MessageAttachment` pins both `assetID` and `versionID`
- advancing an asset does not move historical Message attachments
- deleting a Conversation removes its attachment relation without deleting the
  shared asset/version
- invalid attachment validation rolls the `Send` transaction back
- Stage 1 contains no physical FileAsset path or backup implementation

## 7. Stage 1 closure blockers

RED
- ref: `probe/closure-blockers-red`
- sha: `ba36986f798ae702af806f656b770807c74b2c29`
- run: `35585011102`
- classification: clean behavioral assertion-red
- compile errors: 0
- intended behavioral issues: 3
- note: the original RED attempt was discarded because `import GRDB` introduced
  an independent `PersistenceError` name ambiguity. The accepted probe compiled
  and failed only the three intended corrupted-`ProviderInstance` assertions.

GREEN
- merged main SHA: `bb64ada267ad00fe32dd0bf2efca56ac4892d5dd`
- final branch CI: `35586649825` — success
- main CI: `35587651315` — success
- test-host restarts: 0

Closed blockers
- Z-11 — corrupted `ProviderInstance` storage fails closed
- Z-12 — GRDB is constrained to exact version 7.11.1
- Z-13 — stale current-state comments were corrected without erasing historical
  Stage 0 notes

## 8. S1-05 — Stage 1 closure Gate

S1-05 intentionally has no RED probe.

The first Gate implementation run, `35589060462`, failed because its test
fixture encoded SSE frames without the blank-line event boundary. This was a
test-fixture/specification defect, not production RED evidence. Production
SSE truncation semantics were left unchanged.

The fixture was corrected without modifying production code.

GREEN
- gate SHA: `1b7394b4545861b0645962dcf8bf4954aaa9279b`
- branch CI: `35590036983` — success
- main CI: `35591060670` — success
- suite: `Stage 1 closure gate`
- FakeProvider stable text Streaming: PASS
- DeepSeekProvider adapter stable text Streaming: PASS
- disk-backed saved Conversation recovery after reopen: PASS
- test-run starts: 1
- test-host restarts: 0
- branch result: 269 tests / 32 suites passed

The DeepSeek Gate uses the real `DeepSeekProvider` adapter and its real SSE
parsing/normalization path over `FakeHTTPTransport`. Ordinary CI does not call
the live DeepSeek service or require a real third-party API key.

## 9. Probe-ref disposition

Retain the accepted evidence refs:
- `probe/s1-01-red`
- `probe/s1-02-red`
- `probe/s1-03-red`
- `probe/s1-04-red`
- `probe/closure-blockers-red`

Do not delete or repoint them as part of Stage 1 closure.

S1-05 has no RED probe by design.

## 10. FileAsset product guard

- Selected policy: Policy A
- managed physical storage location: `Application Support`
- device/iCloud Backup: included
- `isExcludedFromBackup`: not set
- user-visible Documents storage: not selected

The authoritative Blueprint decision is
`ac765ab57554e16ae2abbe017ca80c21ef8bedfe`.

Stage 1 implements only the logical FileAsset / FileAssetVersion /
MessageAttachment identity boundary. Physical ingest, copy, delete and
backup-attribute wiring are deferred to Stage 3.

Stage 3 must re-read this policy before implementing physical attachment
storage. A new product decision is required only if a later implementation
intends to change this policy.

## 11. Final Gate

The Blueprint Stage 1 Gate is satisfied:
- Provider/Repository minimal harness: PASS
- FakeProvider stable text Streaming: PASS
- DeepSeekProvider adapter stable text Streaming: PASS
- saved Conversation survives a disk-store close/reopen cycle: PASS
- full AgentRuntime required: NO
- ordinary CI depends on a live third-party Provider: NO

## 12. Explicitly deferred beyond Stage 1

- full AgentRuntime state machine
- RunProjection and business-event flow
- Parent Run ↔ Assistant Response runtime mapping
- Stage 2 execution-snapshot semantics
- ToolRuntime
- Conversation UI
- physical FileAsset ingest/copy/delete implementation
- Soul
- Memory
- Skill
- MCP
- Subagent
- live third-party Provider smoke tests in ordinary CI

## 13. Stop boundary

Stage 1 is CLOSED.

Do not begin Stage 2 from this closure change.

Stage 2 starts only after a new explicit planning/review round.
