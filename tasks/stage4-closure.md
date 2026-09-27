# Stage 4 implementation gate

> Status: **implementation Gate passed at `1c2c79b`; integrated into `main` by PR #10**.
> Blueprint baseline: `596a84d4b58769e3e7b838be95edcb43f9e0ec82`.
> Stage 4 closure branch: `codex/stage4-closure`.
> Gate test commit: `ae3546aac535113a6987509d5658f637c2e9f3f1`.

This record separates the Stage 4 implementation Gate from integration into
`main` and from on-device acceptance. PR #10 merged at
`4268a687332080e1942beb2747338fb9f8e8bb4b` on 2026-09-27.
The Blueprint's Stage 4 Gate is that an
old Conversation keeps using its bound SoulVersion and that Secrets do not
enter Prompt. The Stage 3 long-conversation, keyboard, Streaming, reading
position, performance and accessibility acceptance is tracked separately in
`tasks/stage3-device-acceptance.md`.

## Scope and evidence

| Blueprint Stage 4 item | Implemented boundary | Evidence |
|---|---|---|
| 1. Prompt layering | Pure `PromptComposer` assembles prepared Runtime/Safety, Provider Adapter, Zen Core, optional Soul, history and current user content. Soul style guidance explicitly yields to higher-priority rules and the current user. | `PromptComposerTests`, `PromptHistoryIntegrationTests`, `SoulPromptIntegrationTests` |
| 2. Version metadata and snapshot | Preparing freezes Core/Safety revisions, adapter text and the effective immutable SoulVersion ID. The actual Provider request uses the same resolved version. Unknown built-in revisions fail instead of falling back to current text; old snapshots without Soul still decode. | `ExecutionSnapshotTests`, `PromptHistoryIntegrationTests`, `SoulPromptIntegrationTests` |
| 3–4. Soul Store and versions | A global Soul points to immutable SoulVersion records; edits create a new version with compare-and-swap pointer updates. | `SoulPersistenceTests`, migration and rollback cases |
| 5. Conversation binding | The first committed Send binds a new Conversation while Soul is enabled. Later global edits cannot rebind it. Disable pauses injection; Conversations created while disabled remain unbound. Binding follows deletion and undo semantics. | `SoulBindingTests`, `SoulPromptIntegrationTests` |
| 6. Soul Settings UI | Deferred because the App has no formal Settings host/IA. Stage 5 item 15 owns that navigation; the target page remains `Settings → Agent → Soul`. | Blueprint Stage 4 item 6 and Stage 5 item 15; `NewConversationView` currently presents only provider/model setup |

## Gate checks

- The actual `ConversationRuntime` request, observed through a recording Provider,
  uses the Conversation's pinned SoulVersion after the global version changes.
- A disk-reopen test rebuilds `PersistenceStore` and `ConversationRuntime`, then
  verifies the next real Provider request and the new Run snapshot still use the
  original bound version. [CI `36235534612`](https://github.com/54zhien/Zen-Agent/actions/runs/36235534612)
  passed: 20 XCTest tests, 620 Swift Testing cases in 98 suites, and one Composer
  UI test. The new restart test passed inside the Soul prompt integration suite.
- The global enable flag, binding and version text are resolved in one database
  read; the same resolved record supplies the snapshot ID and request text.
- A test credential value is absent from both recorded Provider messages and
  the encoded execution snapshot. Soul instructions do not alter exposed Tool
  schemas, model capabilities or user Quote content.
- At the Gate test commit, PRs [#6](https://github.com/54zhien/Zen-Agent/pull/6),
  [#7](https://github.com/54zhien/Zen-Agent/pull/7),
  [#8](https://github.com/54zhien/Zen-Agent/pull/8), and
  [#9](https://github.com/54zhien/Zen-Agent/pull/9) were stacked drafts with
  passing branch and PR checks. PR #10 integrated their changes into `main`;
  those earlier PRs remain closed rather than independently merged.

## Integration and device boundary

The current App exposes provider/model setup, but no general Settings host.
Adding a temporary Soul page here would contradict the Blueprint's Stage 4/5
dependency. Stage 4 service, binding and request semantics can pass their
implementation Gate while the user-facing Soul editor waits for Stage 5.

The Stage 4 device candidate is the unsigned Debug
`ZenAgent-Stage4-840a2e2-device-test.ipa` for the user's own signing flow.
Its source is `840a2e2f7a0420a01af1c0d2450ea3f7afbaaebb`, its SHA-256 is
`72a7224b3ad05342dbcff60ed4bb912beb2abe1dfd69e520aed2fc8faab3d678`,
and its production inputs match the PR #10 merge at `4268a68`. PR #12 later
changed the Conversation Pane reading-position behavior; this existing IPA does
not contain that change. The exact device acceptance scope is recorded in
`tasks/stage3-device-acceptance.md`.
