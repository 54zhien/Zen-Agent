# Proposed Sidebar native-host visibility diagnostic

**Status: all prior controls removed; notification and edge-preference diagnostics next.**

The owner froze UI and requires a stop before UI-affecting changes. Existing
permission covers test adaptations, narrow nonvisual interaction diagnosis, and
the earlier specific style/mask controls. This proposal has a different visible
effect and was therefore presented separately. The owner authorized temporary
page hiding, further root-cause diagnosis and restoration after testing; finalized
product UI remains frozen.

## Evidence and question

The unchanged Rail passes a semantic tap in isolation at the exact production
Settings frame. Full-page baseline retains the original AX failures. Independent
style and mask omissions, page hit suppression and fixture reading-control
omission did not solve them. SwiftUI page AX omission did not actually remove the
native subtree, so it cannot exclude that boundary.

Question: does removing the retained native foreground page from rendering and
AX after Sidebar settlement restore the unchanged Rail's semantic hit target?
This is a diagnostic, not a proposed product behavior or established root cause.

## Exact visible impact

Only a DEBUG test process with a new explicit launch flag would hide the native
foreground conversation host after Sidebar is fully open and settled. The
conversation page, Composer, and host-owned decoration would temporarily vanish;
the unchanged Rail and remaining App Space background would remain. Opening
animation runs normally before hiding. Closing clears the diagnostic override.
Route entry also clears that override; ordinary overlay visibility remains
authoritative, and the host returns through its existing dismissal path. No
style, geometry, press spring, haptic trigger or route is replaced.

The host/controller/content stay retained; do not remove/recreate them or change
their model, layout, transform, reading position, editor or navigation state.
Never interpret this temporary disappearance as an acceptable final UI fix.

## Scope and checks after approval

- `App/Workspace/ConversationSurfaceHost.swift`: DEBUG-only visibility control at
  the host boundary. Gate on positive settled Sidebar progress, reset on closing,
  cancellation, return, disappearance and flag absence. Audit existing visibility
  ownership so normal workspace/return visibility is never overwritten. Use an
  independent diagnostic visibility gate: do not call or replace
  `setWorkspaceVisible`, whose ordinary overlay path resigns the editor and
  detaches hosted content. That path remains authoritative on real route entry.
- Existing DEBUG native receipt: report diagnostic mode plus actual host hidden
  state and frame. Confirm the expected visible/AX omission actually occurred.
- `Tests/ZenAgentUITests/SidebarUITests.swift`: separate baseline and flagged
  launches, retaining unique/spoken name/enabled/frame/hittability/real Settings
  route assertions and before/after screenshots plus AX snapshots. Add explicit
  omission verification and restoration checks; a failed precondition makes the
  control inconclusive. Baseline must retain RED for causal interpretation.
- `.github/workflows/ci.yml`: select only these diagnostic cases in the focused
  profile. Do not run class-selected/full integration with variants present.
- Run local syntax/hygiene checks, push exact source, run real XcodeGen/build and
  tests in macOS CI, and preserve every failure/artifact digest.
- Remove every flag, visibility override, extra test and temporary selector after
  collecting evidence. Verify product byte equality with frozen `eb39a65` before
  considering a separately reviewed minimal repair. A successful diagnostic is
  not a successful integration gate.

## Failure and cancellation

If the run fails, times out, or the host does not actually disappear, preserve
that result and restore diagnostic source. Do not weaken existing assertions,
keep the page hidden as a fix, merge, or start S6 on diagnostic success alone.
Production UI changes beyond this specific temporary omission still require the
owner's separate direction.

## Nonvisual follow-up after visibility restoration

Independent review and the native snapshots identify full-phase card Button
traits around the actual conversation despite `isAccessibilityElement=false`.
The task record contains the observation and its causal limits. After restoring
all visibility code in `c91e76f`, run a separate DEBUG control that changes only
the full-phase Surface trait from `.button` to `[]`. Leave its label/hint,
hierarchy, physical hit-testing and all pixels unchanged. Require a native trait
receipt and disappearance of the exported full-page Button role, preserve native
pane/editor/identity and every original Settings assertion, and add a semantic
Settings re-entry only after the control and coordinate/hit checks pass. An
ineffective exported-role omission is inconclusive. Remove the flag, extra case
and temporary profile selection after native evidence; cleanup base `c91e76f`.

The role omission took effect (2 exported Buttons to 0) but retained the AX
failure. All role-control source is restored. The task record defines a further
observation-only comparison of native hit ancestry in the full and isolated
fixtures; preserve positive/negative validity controls and remove its probe after
evidence. It changes no product layout, style or geometry.

## Probe observer-effect follow-up
Ancestry39729604809 invalidated the required instrumented-full RED control: original full stays RED, but both probed contexts are GREEN. Zero-sized immediate glass ancestor appears in both passing contexts. All ancestry source has been removed atb493ba4.
Compare four independent launches: original baseline; same 1pt noninteractive native probe with isAccessibilityElement=false and passive constant getter; same probe with isAccessibilityElement=true and same constant getter; original active JSON getter as replication control. Same ID/label are retained, so passive-native exported node count must be recorded rather than assuming false removes the whole native container. Passive getters return before native hit or AX reads. Probe receipts occur before Settings presentation. Each launch retains original hit/frame/coordinate assertions; no source UI/layout/style changes are adopted. Remove diagnostic source/test/profile after evidence, cleanup baseb493ba4. Native results are pending; local parsing alone is not completion.

Native39731842465 built and ran4 cases; baseline retained2 AX failures, all three probes passed. Both passive variants exported one node. Active reads are unnecessary, but AX exposure remains. Controls removed indf5862b, product matches frozeneb39a65.

## Metadata/composition discriminator

Compare four launches: original baseline; unchanged passive-native positive; same native class/insertion/size with false AX flag and no identifier/label/value; same-size Color.clear background. The metadata-free getter returns nil immediately. The positive root branch remains unchanged; Color.clear uses a separate DEBUG fixture branch. A new branch may itself affect composition, so baseline RED and positive GREEN are mandatory. These controls can locate sensitivity to metadata or composition, not prove an internal framework cache mechanism.

Before Settings presentation, retain the original hit/frame/route assertions, capture full AX and screenshot, and count the known diagnostic `(0,62,1,1)` AX slot. Require its absence in metadata-free and clear arms, and no diagnostic identifier; a failed omission precondition is inconclusive. Existing named fixture probes at `(0,0,1,1)` remain. No new drawing/layout/style/haptic change. Restore the three source/test/profile files todf5862b and remove the temporary native file after evidence; no full gate while variants exist.

Native39734092779 built:4cases/7failures. Baseline one-edge entry failed before original AX checks; primary mounted/ready/eligible owner stable but no edge begin/callback observed. Clear retains originalAXRED/slot0. Metadata-free hit+coordinate pass but unnamedslot1 remains; omission precondition fails. Passive positive passes. Overall causal comparison incomplete. All source removed indef2740; frozen product restored.

## Completed AX omission and fixture-layer discriminator

Two remaining boundaries can be tested in independent launches in one native build:

1. Same metadata-free native view, with matched outer accessibilityHidden(false/true) after the frame/hit modifier. Require slot1 and hit GREEN in the visible positive, slot0 in the hidden control; complete snapshots must also exclude a relocated unnamed node. Any failed precondition is inconclusive. No native geometry, drawing, layout or behavior changes.
2. Same preview fixture model/store/assembly and startup/cancellation logic, with its three test-only overlay modifiers omitted as a group. The earlier reading-Button omission left those modifiers intact. Both decorated and plain branches retain bottom padding, error repair and the same task body (shared async function, no new Task). The five workspace readiness probes remain. Require expected preview-ui-11 pane and actual absence of all four fixture-control identifiers. This tests fixture composition without changing production AppShellRootView or frozen UI.

Six cases: original baseline; Color.clear negative; metadata-free native visible positive; native AX-hidden; fixture without overlay layers with original route checks; separate cold launch of the latter exercising real Settings.tap() and destination receipt. No coordinate fallback in the semantic case. Preserve one edge gesture and all original hit/frame/coordinate assertions. Require expected loaded pane before gestures and record primary receipt. If Settings is absent, retain existence and entry failures then return before invalid label reads; do not invent a hit/route result. Baseline must reproduce original AX RED and visible native positive must reproduce GREEN for comparison validity.

Remove all temporary source/test/profile edits after evidence, cleanup basedef2740; added native file is deleted. No full gate/merge while controls exist. A recovered diagnostic branch is not a production repair, and no UI-related permanent hosting change is authorized by this plan.

Native39736662881 built6cases/9failures: baseline again never opened; plain-fixture omission effective but AX still RED and cold semantic tap not executed; native hidden omission ineffective (unnamedslot1 remains); visible native passes; clear throws invalid activation point before coordinate route. All temporary source restored and pushed at128cc71, frozen product matches. Full evidence is in the task record.

## Notification and native edge-preference discriminator

Do not add any view or AX node. Five independent launches use restored fixture/root: unflagged baseline; matched no-post async path; no-post plus read-only root/child edge-preference measurement; one-post route; separate cold one-post semantic tap. Expected pane and existing one-edge/hit/frame/coordinate checks remain. No gesture timing or retry changes.

The native controller owns a DEBUG successful-opening UUID marker, generation token, schedule/callback/post counters. Only native animator completion at .end (or successful Reduce Motion completion) with current navigation settlement UUID and open state may mark success. The later matching native UUID-to-nil update consumes it. Both no-post and post modes enqueue the same weak callback and run identical guards; only the final UIAccessibility.post differs. Invalidate on changed Sidebar state, cancellation, real visibility/input-suppression/return-proxy changes. Callback requires same window, foregroundActive scene, visible/full controller, no overlay or input suppression, open/not-dragging/settled navigation and unchanged token. One post maximum per consumed completion; no retries. Counters prove calls only, not assistive-app processing.

Measurement reads only existing window.rootViewController and the bounded public childForScreenEdgesDeferringSystemGestures chain, without loading views or calling update methods. Its separate no-post control must retain the AX failure to exclude reader-induced recovery. Preference values are requested configuration, not system arbitration acknowledgement. Apple documents layoutChanged as a layout notification, not a cache invalidation guarantee; GREEN only establishes notification-sensitive behavior. See [notification](https://developer.apple.com/documentation/uikit/uiaccessibility/notification/layoutchanged), [post](https://developer.apple.com/documentation/uikit/uiaccessibility/post(notification:argument:)), and [edge preference](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferredscreenedgesdeferringsystemgestures).

Restore ConversationSurfaceHost.swift, WorkspaceSidebarInteraction.swift, SidebarUITests.swift and workflow to128cc71 after evidence. Root app and preview fixture remain frozen throughout. No permanent UI or hosting change is proposed.

Native39740636134 built5cases/10failures. All openings settled; no-post receipts1/1/0 and post receipts1/1/1 all retain AX failure. Post semantic did not tap; post/no-post/measurement coordinate routes pass, baseline activation exception precedes route. Measured preference2 before gesture,0 after open; earlier failed-entry cause remains unknown. All4files restored128cc71; frozen product equal. Complete evidence is in the task record.


## Existing-probe physical-hit receipt

The earlier ancestry comparison inserted a new UIView and changed the result. Next use only the existing primary SurfaceInteractionProbe value channel; no view, AX node, SwiftUI branch, layout flush, notification or injected touch is added. A DEBUG environment flag permits one cached physical window.hitTest sample at the measured fixture screen point(62,812), only while foreground/full/visible/open/progress1/settled with no overlay. Record public physical ancestor geometry, transforms, clipping/interaction/visibility and pointInside only; do not read AX metadata. The actual Settings frame/center must match this fixed diagnostic point before interpreting the receipt.

Three independent cold launches: unchanged baseline; sampled original route; sampled semantic tap only if original hit checks pass, without coordinate fallback. Keep one-edge and original hit/name/unique/enabled/frame checks. If sampling changes RED to GREEN, it is another observer effect, not a repair. If it stays RED, compare physical ancestry with the historical probed GREEN while preserving that comparison's source/run limits. A failed entry or missing cached sample is an invalid precondition.

Restore ConversationSurfaceHost.swift, SidebarUITests.swift and workflow to cleanupddf4c9e and remove the temporary helper file after native evidence. No permanent UI changes.

Apple documents [isHittable](https://developer.apple.com/documentation/xcuiautomation/xcuielement/ishittable) as hit-point computation, and permits nil event for an out-of-event-handler [UIView.hitTest](https://developer.apple.com/documentation/uikit/uiview/hittest(_:with:)) query. The physical query is valid observation, but is not proof of a delivered touch or VoiceOver activation; keep actual route/semantic receipts separate.

Task8 run39743930739 was cancelled after approximately25minutes to collect phase evidence. It had not completed compilation (last ZenAgentTests compile), zero UI starts/samples and no compiler error before cancellation. No runtime conclusion. Partial artifact/source preserved; all three files restoredddf4c9e/helperdeleted.


## Physical receipt with isolated UI compilation

Task8b retains the same three UI controls and native query. Add a temporary XcodeGen scheme building App and ZenAgentUITests only, selected solely by sidebar-hit-path; the normal ZenAgent full gate is unchanged. The cancelled run never reached UI and still compiled all unit tests. This is build-scope isolation, not acceptance without unit tests. Move only the new heterogeneous context dictionary from the generic host getter into the non-generic diagnostic helper; no runtime behavior or invocation timing changes, and no claim that this dictionary caused slow compilation.

Use the focused job's existing40-minute native limit to obtain an actual outcome rather than cancelling again based only on the prior run duration. Restore project.yml, host, test and workflow to cleanup9ce19d7 and remove helper after evidence. A cancellation/build failure remains distinct from UI RED/GREEN.

Read-only follow-up, not implemented: SurfaceHitView overrides hitTest to pass the exposed Sidebar strip through, but inherits root point(inside:) for the whole viewport. SidebarSurfaceTests cover physical(30,130)/(150,130) routing, not paired root pointInside/hitTest at Settings center(62,812); relevant history has no native root pointInside control. Existing-probe ancestry captures the final hit, not the skipped foreground root. Apple documents point(inside:) against view bounds; whether this distinction explains XCTest remains unproved. Await Task8b before choosing any narrow native contract control.


### Task8b native outcome and restoration

Source74f97d8cb2bb238133b4c62e3a5316ad536b9410 / run39748276274 / job119722169256 generated and built successfully with the temporary UI-only scheme. Native result:3 failed cases,6 failures,0 unexpected. Original baseline failed its first edge opening and Settings existence; no original AX comparison is valid for that launch. Both sampled launches settled open with progress1, full visible/unsuppressed host, no native/navigation drag or settlement, and matching host identity. Settings remained unique/enabled at(34,784,56,56), center(62,812). Both retain the original AX/hit failures. Independent semantic case did not tap because its hit guard failed; sampled route opened settings-page by app coordinate. Coordinate success is diagnostic only.

The existing-probe cached query returns UIPlatformGlassInteractionView at Settings center in both RED launches. Its physical ancestor geometry, pointInside, clipping, visibility, alpha, interaction and transforms exactly match historical d3ab full+inserted-probe GREEN after excluding object addresses. The zero-sized inherited ancestor occurs in both. This narrows the discrepancy to hit-point/AX mapping versus physical native routing; it does not identify a framework bug or prove a particular skipped foreground host is responsible. Sampling is cached, not continuous, and a nil-event query is separate from a delivered touch. The raw AX snapshots retain only the existing five1pt probes and the same Settings frame; no diagnostic view/node was inserted.

Artifact12412762451, digest sha256:adfe9a2eb098a4a223ff7be83720b91c9046870fca0cfb5664d72eb4e33129ab; downloaded source receipt matches exact SHA. All four temporary source/test/workflow/project files restored byte-for-byte to9ce19d7 and helper deleted. App/Config/Resources/project.yml again equal frozeneb39a65. No diagnostic code adopted, no merge or S6 implementation. The separate intermittent first-edge recognizer failure remains unresolved.


Owner stop ruling: 2026-10-22, "实在解决不了就先算了". Stop further diagnostics. Prepared Task9 native root pointInside control was NOT committed/pushed/dispatched and has NO native result. All6tracked preparation files restored to704263e. Product App/Config/Resources/project.yml equals frozeneb39a65; no temporary hiding, probe, point override or diagnostic scheme retained. Keep prior RED/cancelled run evidence. Root cause remains unproved; no merge, no S6-03 implementation. User may explicitly resume later.
