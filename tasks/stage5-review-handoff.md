# Stage 5 当前代码与整体 review 交接 — 2026-10-05

剩余 Files、Settings、Visuals 的完整代码 gate 与新的全阶段只读审查均已完成。
这是代码与审查交接；真机验收保持开放。

实际 checkout：C:\Users\Azusa\.codex\worktrees\s5-history-handoff\Zen-Agent。
分支 codex/s5-16-visuals，draft PR33，base Settings PR32。
Files、Settings FULL 已关闭。Visuals 在真实 RED 后完成原生 Ink、Current 边缘和设置；
开关修正与原生 Provider Save 点击区修正的 targeted 双跑均已通过。
Visuals profile-free FULL 已在 db30ed60/tree79f55ccb 双跑通过。新的全阶段审查
未发现具体 Critical、Important 或 Minor 代码缺陷，详见 [完整报告](stage5-code-review.md)。
主 checkout/main 干净且未修改，HEAD eec3eb38c3d4869a58031449f303f04dec55d0fd。
本地与 connector commit SHA 不同但每次发布验证源码 tree 相同；不要 reset/rebase 对齐 SHA。

Blueprint：C:\Users\Azusa\Desktop\Zen Agent。main baseline99d30b8；批准补充
remotee6d8c5f/local476562c treef53425a785e64d864b488e598ef388df9d23ab2e，PR5未合并。
用户授权完成剩余 Stage5，再整体 review；不 merge/main push/IPA。真机验收开放。

完整历史保留在各 slice record 和外部目录
C:\Users\Azusa\Documents\Codex\stage5-handoff-2026-10-05。
START-HERE 与 preparation-drafts.zip 是历史；不能覆盖已更新实现。
CURRENT-STATE.md、settings-ci-receipts.json、visual-ci-receipts.json 是当前续接点。
本地只留下 __pycache__ 静态检查产物；所有授权测试草稿已实现并进入对应源码 gate。
## Current code gates

| Slice | Review entry | Exact tested tree / result |
| --- | --- | --- |
| S5-05 Browse / Snap | PR #22, `tasks/s5-05-card-browse-snap.md` | Head `bca95d9bd1e083be1f9e1c21ab6a0dc1f85f64c6`, tree `65fd51a4bf93c8a0140451e14f3d825d2f3a0daf`; exact-head PR CI 36575722211 / push 36575717552 successful |
| S5-06 New / Pin / Rename | PR #23, `tasks/s5-06-new-pin-rename.md` | Head `56c8425dd72c818529b4d2f9a2c5617a89049000`, tree `8ce365e715b9e4c2bbe1ddb3062e2ccabff1d1cb`; exact-head PR CI 36598142908 / push 36598136739 successful |
| S5-07 Delete / Undo | PR #24, `tasks/s5-07-delete-undo.md` | Head `a58dc925509a7dcf2e45838cd8a27dd3e11c133d`, tree `d9871431c53bcba128529ec8bc5169a05d66bdf8`; exact-head PR CI 36629976053 / push 36629970608 successful |
| S5-08 Split targeting | PR #25, `tasks/s5-08-split-targeting.md` | Head `f419a9755ae3e48f687c684523c46c6562c9c37e`, tree `67b899c9ebc1cc2400459e8b35576bf0df3f6abd`; exact-head PR CI 36661218548 / push 36661214158 successful |
| S5-09 Split container | PR #26, `tasks/s5-09-review.md` | Head `08e950abf55d895f502fec2139262343275783f4`, tree `1d66027b2b4875245ffc492e011f6128798c3ab0`; push37139550698 passed837 Swift/20 XCTest/30 UI. Parallel PR37139554202 failed an older Browse test's initial Lift admission; retained explicitly, not a second GREEN. Subsequent cumulative FULL gates pass that path |
| S5-10 Resize / close | PR #27, `tasks/s5-10-resize.md` | `332d2a55416b6a6e03822556274db070db557319` / tree `ba0268272439a59eb0f3fa43bd46618b34a89746`, push37163392220 and PR37163394761 passed the full source gate: XcodeGen/build,852 Swift /20 XCTest /35 UI, no host restart/retry |
| S5-11 Rotation / iPad axis | PR #28, `tasks/s5-11-rotation.md` | `ad10ca848a3f1d1d3ba7058643ac0f7e0f53dab5` / tree `96300c087a4d272d77b55c947336bcd9447b98a2`, full push37169724633 and PR37169727362 passed generation/build,861 Swift /20 XCTest /39 phone UI (one expected Pad-only skip), plus one actual Pad case in each run; no retry/host restart. Historical failures remain recorded |
| S5-12 Sidebar | PR #29, `tasks/s5-12-sidebar.md` | Behavioral RED and historical failures retained. Scene-root edge remote `b6ba4473b23bbd738f5c02ce414df893eba2af9a` /tree `e4e713dd7176ad601c93d40e1a3f6b1011007d04` passed both targeted phone gates:873 Swift/132 suites,20 XCTest,all7 Sidebar UI. PR actual Pad passed; push Pad app launch timed out before axis execution. Full profile restored in local `d89aa12` /remote `9218e8c7fc9e5a11baa53bafda4787fb962768c0` /tree `6c1b9095f933b111590025a6d0aadd9a6bfe3bd1`. PR37180642485 /push37180640443 both passed full generation/build,873 Swift/132 suites,20 XCTest,46 phone UI (one expected Pad-only skip,zero failures), plus one actual Pad axis case each. No retry/test-host restart. Full Sidebar code gate closed |
| S5-13 Search | PR #30, tasks/s5-13-search.md | Remote6a217da90153e04a5e0120195610aaae95ab9a35 /tree81dfd8c48e3cb17a453749432fc0f6272bbdcb24 passed full push37195522196 and PR37195524247: generation/build,894 Swift/136 suites,20 XCTest,48 phone UI with one expected Pad-only skip and zero failures, plus actual Pad axis once each. Native teardown/keyboard/identity/draft and all Workspace regressions pass; no host restart/retry. Full Search source gate closed |
| S5-14 Files | PR #31, tasks/s5-14-files.md | Remotec9f6e2aa2e5e989c62cd7abe920f74815743c826/treec66db812610c4f84c2dc0c141a58492d067fbc5f: complete push37222392865,PR37222395611,guard37222395686 passed generation/build,912 Swift/141 suites,20 XCTest,50 phone UI with one expected Pad-only skip and zero failures,actual Pad both. Actual native import/export cancellation returns original editor/draft/focus. No host restart/retry; historical failures retained |
| S5-15 Settings | PR #32, tasks/s5-15-settings.md | Remote2d501a6be6a39ee1194a3302c1e5241e23771fb8/tree437d5de40a08affbb25dd341db8d9dc9e519a3f5: full push37236474441,PR37236477630,guard37236477646 passed XcodeGen/build,930 Swift/147 suites,20 XCTest,53 phone UI with one expected skip and zero failures,actual Pad both. No restart/retry; code gate closed. Prior40min incomplete PR retained |
| S5-16 Ink / motion / highlight | PR #33, `tasks/s5-16-visuals.md` | Remote `db30ed60a1c4c164f03892b8421b0351a7d45bf4` / tree `79f55ccb5d2ff9558eaae8e5111830f409ecca91`: profile-free full push37247975877, PR37247978542 and guard37247978538 passed XcodeGen/build,942 Swift/151 suites,20 XCTest,54 phone UI (one expected Pad-only skip,zero failures),actualPad both. One Swift start/no host restart/retry each. FULL code gate closed; fresh whole-stage review completed with no concrete Critical/Important/Minor finding |

PR readiness refreshed2026-10-05: #22/#23 Ready/open/unmerged; #24-33 draft/open/unmerged. Exact branch heads and bases are in live-stack-2026-10-05.json. Main remains eec3eb38c3d4869a58031449f303f04dec55d0fd; no merge/main push/IPA.

## Approved spatial behavior

- Either occupied Split Pane can Lift; returning to its original Card restores
  the Split. A different Conversation replaces only the initiating Pane.
- Returning to the Conversation already occupying the other Pane selects its
  existing owner. It must not duplicate a Composer or move a Run's ownership.
- Ratio and axis survive Return; focus follows user interaction, not streaming.
- iPhone landscape keeps the App Space card stack. Split temporarily presents
  its last active Pane. Edits, Send/Run and model changes belong to that Pane;
  the other owner survives unchanged and may keep streaming.
- Full Conversation Sidebar opens only from the leading screen edge, with an
  equivalent accessibility action. Its top-level destinations are Search,
  Files and Settings; Agent configuration lives under Settings.

## Current tested source and review status

Final tested source: local `174c23cad7e9bb1fda698e6fcab166cf5a9dde20`,
remote `db30ed60a1c4c164f03892b8421b0351a7d45bf4`, identical tree
`79f55ccb5d2ff9558eaae8e5111830f409ecca91`. Full units74.272s/80.325s,
phoneUI1413.836s/1424.781s, actualPad107.610s/173.815s. Raw completed
native logs are archived outside the production checkout. Historical S5-09
PR failure and Settings timeout remain explicitly distinguished in the table.

Fresh reviewer `stage5_final_review` completed the cumulative main→source diff
and inspected integrated Stage5 foundations as context. The [saved report](stage5-code-review.md)
records no concrete Critical/Important/Minor code finding, its coverage and limits.
It ran no new tests and does not establish physical-device acceptance.

The first documentation-only closure ab5cd44/tree d4ffc8b preserved that source.
Push Pad passed90.066s; PR37252198078 Pad job111581981090 failed once at
WorkspacePadAxisUITests:33, a global-app-frame landscape readiness query.
All later native axis/drag/ratio/editor assertions passed; the113.271s real
failed case and xcresult artifact11321566067 are retained. Actual video shows
the landscape Split. The [focused review](stage5-pad-readiness-review.md)
supports observing the two live Pane frames instead, keeping the width>height
gate and all native behavior assertions, app-coordinate drag and waits intact.

The same documentation candidate's push phone FULL passed (942/151+20 units,
54UI/one expected skip/zero failures); PR units passed but its first Browse Lift
never entered Card, followed by a missing-Card swipe error. All other UI passed.
One Swift start/no host restart/retry each. Raw artifact11321804529 preserves
correct touch coordinates/0.7s hold/220-point drag and Full video; the trace lacks
the exact native refusal/cancellation reason. The [focused review](stage5-browse-lift-review.md)
covers a bounded12-entry DEBUG UI-test-only gesture trace and test diagnostics.
The same Card prerequisite now stops on failure rather than issuing a cascade
swipe; real input, successful-path assertions and ten-second wait are unchanged.
This adds evidence without claiming the intermittent historical cause fixed.

The following Pad test repair plus DEBUG diagnostics/documentation keeps Lift
policy,Config,Resources,project.yml and CI unchanged. It requires its own
profile-free FULL pair/actual Pad/guard.
Latest exact HEAD/tree and those CI outcomes are in
[PR #33](https://github.com/54zhien/Zen-Agent/pull/33) and external current receipts.
This avoids a self-SHA documentation loop and keeps the failed candidate explicit.
The owner can review the complete stack and, after the latest code gate passes,
proceed to physical-device acceptance. All PRs remain unmerged; no main push or IPA.

## Whole-stage code review focus

1. One Conversation owns one live Pane/Composer; late Open/Return callbacks
   cannot replace a newer owner or overwrite a later ratio/axis.
2. Hidden Split surfaces retain their native editor and consume geometry only after
   reattachment. Resize captures bottom references independently and completes
   only from fresh final layout and native scroll receipts.
   Mutable environment values must be observed inside the once-installed native
   hosting root; capturing a primitive outside it freezes the initial revision.
   Apply the same boundary when connecting Appearance and Return presentation.
   ComposerHostView suppression resigns its editor, and textViewDidEndEditing
   clears the logical focus. Overlay restoration must capture the actual native
   responder before entry and request focus after that same retained owner is
   mounted and input is reenabled; a later logical-focus read is insufficient.
   Device orientation must use the window/scene's full layout context, independently
   of the keyboard-shortened usable Split viewport. A portrait phone with a tall
   keyboard must not become landscapeSingle merely because usable height is
   smaller than width. Return destinations use the actual Workspace frame,
   including embedding/padding, rather than assuming the whole window is its root.
   Cross-owner Return retains an immutable selected Preview descriptor on the
   origin proxy while mounting the existing target host below it with input and
   accessibility suppressed. Native receipts include the actual window frame:
   changing position can preserve bounds, so bounds-only notifications are
   insufficient. Hide the proxy only after the target's fresh layout/scroll
   receipts; interruption after logical commit keeps the selected owner.
   Preview 是另一条边界：S5-04 刻意卸载 Full Pane/native editor，warm Session、
   Composer 与 reading owner 留存，Return 重新挂载原生内容并恢复草稿/锚点。
   Settings 等覆盖页关闭保留原生 editor；不要把两种生命周期混为一谈。
3. Close preserves the survivor's physical host/editor and both Conversations'
   Run/Session lifetime. Delete alone follows its explicit cancellation rules.
4. Search matches the actual visible display title, including its bounded
   provisional fallback, with stable paging and deletion/stale-query guards.
   Existing Full Open checks the history snapshot after an asynchronous read;
   the S5-13 implementation reads lifecycle again at owner commit. Its compiled
   regression uses two real WAL connections to commit deletion during the
   history snapshot and rejects the stale result while preserving the origin.
   Full Search UI/source gate passed on tree81dfd8c48e3cb17a453749432fc0f6272bbdcb24.
5. Files import/preview/export uses verified immutable managed bytes. Removal
   protects durable attachments, both Panes, warm drafts and pending Send
   snapshots; metadata removal precedes orphan-byte cleanup.
   ManagedFileStore already uses a static process-wide operation lock across
   instances. Reuse that serialization; do not introduce another lock or infer
   that two instances currently have independent publish/cleanup protection.
6. Settings persists only real supported controls. Global defaults, old Soul
   bindings and frozen requests retain their separate scopes. No credentials
   enter summaries or logs. Appearance applies across native and SwiftUI layers.
7. Effects have bounded layer count/displacement, preserve selected identity,
   and freeze appropriately for Reduce Motion, energy/thermal and scene state.

## Remaining product answers

Marked-text navigation/focus and light-mode Ink treatment were asked as optional
owner preferences. Current conservative assumptions block navigation while text
is marked and keep Light Ink off; these do not block independent implementation.
An explicit Pad axis stays selected. Soul follows the verified explicit Blueprint global-enable
baseline: disable pauses injection, retains versions/bindings, and does not alter
frozen Run snapshots. An earlier optional question is not evidence that this
baseline was undefined. Record later owner changes explicitly.

Startup is already partly decided in the stage plan section10 item2: the
2026-09-24 owner decision starts on New, creates the first Conversation only
at Send, and permits provider configuration from New. Keep that approved
entry while connecting the formal Settings destination. The navigation note's
general startup-TBD sentence does not erase these explicit sub-decisions.
The earlier startup question overlooked that subsection and is not a gate.
Same-process background of20min or less restores Single; more than20min returns
to New+Recent. Warm drafts remain in the existing Session owner.
Cross-process draft persistence and new Split/App Space cold-start restoration
remain separate decisions; this work does not change their policy.

## Deferred physical-device evidence

The existing font manifest marks Anthropic Sans distribution rights as
unverified and a release blocker (`Resources/Fonts/README.md`). The Settings
About page must report the real bundled notices; adding that page cannot
establish rights absent from the manifest. No font replacement is authorized.

- Exact installed source SHA/tree and device/OS/build provenance.
- Reading position and comfort under resize, simultaneous streams, long Turn
  content, keyboard changes, selection, IME composition and Dynamic Type.
- Handle hit area, snap/rubber-band/close thresholds, haptics and cancellation;
  rotation/axis changes during Lift, Card preparation and Return.
- VoiceOver/Switch Control operation and meaningful focus after transitions.
- Peak memory with long histories and warm sessions; frame pacing, CPU/GPU,
  energy, thermal behavior and stable renderer/native-view counts in Instruments.
- Real picker access, large-file cancellation, preview/export bytes and storage
  protection/backup behavior on the device.

Passing simulator CI does not close these observations. Record failures and
unavailable checks explicitly in the final handoff rather than treating plans,
test scaffolding or an earlier green head as current acceptance.

## Removal cleanup review focus

S5-14 review found a reachable post-commit cleanup/catalog mismatch. Actual
existing-API RED reproduced the stale catalog/feedback with real metadata commit
and refusing FileManager. The repair is unit GREEN in both latest full runs:
refresh authoritative rows even on post-commit cleanup failure, show explicit
pending cleanup and retry only real orphan cleanup. This handoff preserves that failure and its tested fix. Metadata commit and byte cleanup have separate failure states.
Retry must use fresh version references under the existing global file lock,
remain off MainActor, and keep actual worker ownership until drain. The native
picker query must observe true dismissal before attempting an underlay control.
