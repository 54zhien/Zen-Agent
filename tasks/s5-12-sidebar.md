# S5-12 Sidebar — implementation and gate record

The owner authorized completing all remaining Stage 5 before their whole-stage
review and physical-device testing. S5-11's full code gate is the predecessor;
this draft does not close it or authorize skipping it.

## Intent and ownership

Blueprint navigation section13: existing real Conversation, stable Full/Single,
leading screen edge only, about60pt Rail with Search/Files on top and Settings
at bottom. The original Surface moves without narrowing. Timeline/Composer text
selection, marked text, keyboard transition, Lift/Browse/Split, overlays and
system navigation cannot be displaced by the Sidebar recognizer. Stable editing
alone is not forbidden. Opening and closing retain native focus, draft, reading
and Run. Expose the equivalent named accessibility action while keeping children.

Root owns retained navigation state and supplies live spatial admission. A
navigation wrapper owns Rail/overlay composition; a native adapter owns scene
recognizer installation, arbitration and removal. Screen-edge opening uses the
mounted root content view; reverse/tap closing stays on Window. Runtime owns Runs; the existing
Session/Pane/Composer remain their own owners. A cancelled drag restores its
stable endpoint; owner loss/inactive scene closes navigation. Future destinations
stay disabled until their real handlers exist, with no empty pages.

## Prepared compiled UI regressions

Only these existing-production-root UI tests will be published for RED:
native edge and shifted-Surface tap with unchanged width/draft; stable editing
edge and reverse close with retained native editor/focus; interior and Split
rejection; App Space Card rejection; landscape translation retaining the inner
SwiftUI Timeline width and native editor width, not just outer ScrollView bounds.
They use actual native blank-tap sequence
and Lift readiness. No missing production API is used to manufacture compile RED.
Feature model/unit tests accompany real implementation after behavior RED.

The temporary sidebar-red profile is confined to codex/s5-12-sidebar, fixed to
the complete unit target plus SidebarUITests. Local profile guard RED was1 error
in8 tests (the mode was rejected); the minimal guard change passed8 tests.
That is infrastructure evidence only. Main and absent-profile remain full.
Remove the profile for product acceptance; no test retry/host restart is allowed.

## Evidence

S5-11 predecessor ad10ca848a3f1d1d3ba7058643ac0f7e0f53dab5 /
tree96300c087a4d272d77b55c947336bcd9447b98a2 passed full push37169724633
and PR37169727362, including actual iPad axis execution. Sidebar test-only
publication is based on that gate. Pending XcodeGen/build and compiled UI RED.
No Sidebar feature or device acceptance claimed. Keep future Search/Files/Settings
drafts out of this test-only publication. Record exact predecessor/head/tree and
actual CI results here before claiming this slice complete.

### Compiled behavior RED and first implementation

Local68ab381 / remotee9134cde4ff0dc45e4e0859b82325a7e5ae47d1f /
treedcadcd9569af07b8bfc5554cf5f69b93a558985c built in both runs.
PR37171367578 / phone111344835099 passed861 Swift/129 suites and20 XCTest;
five Sidebar UI cases ran: three positive cases failed7 assertions, while Card
and interior/Split rejection passed. Push37171347675 / phone111344820697
also built, passed units and reproduced the same7 assertions, with3 additional
Card Lift observations failing. Preserve that additional failure; it is not
evidence of a Sidebar defect in the unchanged production baseline. Both actual
Pad jobs111344835084 and111344820689 passed. No retry/host restart.

The first implementation uses a persistent Surface center offset, independent
of Lift's transform and unchanged native host bounds/safe-area container. One
Window transport snapshots native host/Pane/window identity, uses raw current
Composer input and consumes reverse/tap close without invoking explicit focus
changes. A shared navigation reference blocks Lift and Timeline blank-exit
until matching native settlement completion; stale completions cannot release
a newer transition. Inactive scene, owner/topology/window changes close it.
Dynamic accessibility actions preserve independent Timeline/Composer children.
Destinations remain disabled until their real feature routes are wired.

Apple's dynamic action builder was checked against current primary docs:
https://developer.apple.com/documentation/swiftui/view/accessibilityactions(_:)
Cancellation alone does not establish SwiftUI gesture arbitration. An added
focused tap-close UI case retains keyboard/editor identity, then requires the
normal blank dismissal to work again after the Rail closes.
Remove the fixed RED profile for this product's full build/unit/UI gate.
Local checks are not a macOS build or a completed Sidebar gate.

First product local54f6694 / remote092b5ebb68b3a502060355542c4174166729e516 /
tree7c43813096e8b4b552a29ee05887c2292f873b6b failed compilation in
push37172447636 and PR37172450208: the raw selection check separated the
unary `!` from its operand. No behavior result follows from those jobs. Correct
the exact lexical error. Also avoid assigning the unchanged native edge setting
during the recognizer's own Pan; only reconfigure it when layout direction changes.

Follow-up local9744bce / remote73d9e3bd709350764fa609fba250aed966d8b395 /
tree6ca748c64a372266dcc92cbb5986f8360c34ca6e failed build in push37172621243
and PR37172624063: the UIView adapter's gestureRecognizerShouldBegin overrides
UIView's existing method and requires `override`. Correct that declaration.
Read-only review separately found P2: selection after opening can make native
opening eligibility false and wrongly block reverse/tap close. Add a delegate
admission regression first, using an unchanged owner/window and deterministic
closing velocity; this policy test is not a physical gesture receipt. Publish it
for compiled unit RED before changing the close predicate. Retain full UI gating
after the correction and keep both compile failures visible.

### Review regression RED and correction

Local730dfdc / remote2bfa71e20e5fa8e0877a6fb982b81540fb0f519e /
tree83c6737c0994f585c7b60f4ea1b693f632216861 passed XcodeGen/app build.
Push37172861692 / phone111349266357 and PR37172864648 /
phone111349263816 ran869 Swift tests/132 suites: exactly one issue at the
new close-admission assertion after opening eligibility becomes false.20 XCTest
passed. This is a compiled policy RED using an existing delegate API, not an
absent-method compiler error or a physical Pan claim. PR Pad111349263854
passed its actual test. Push Pad111349266425 failed to launch the app through
Xcode after112.258 seconds; no axis behavior was observed in that job.

The correction separates opening input guards from closing safety. Closing
requires a visible, unsuppressed same Full/Single host/Pane/window without native
modal presentation. Tap captures its owner at touch-down and revalidates it at
completion. Close touches must descend from the actual shifted Surface; Rail
and overlay controls are excluded. Reverse Pan defers inside selected native
text views. Pan generations prevent late callbacks from resetting a newer owner.
Timeline blank-close uses the measured leading blank margin, not a toolbar/AX
bounding-box coordinate; after close, normal dismissal still requires a fresh
Timeline callback. Native reversal captures the actual presentation center.
Full product CI remains required after removing review-red.

First-Send navigation availability now observes a one-way published-Turn flag
on the existing Pane, updated only when a persisted Timeline is installed. Root
does not subscribe to live token state to refresh its accessibility actions.

### Full-product observation on the close correction

Locald144d7a / remote59dba50b9c1c3e50084465cfbd69ff60f8ff24d7 /
tree6eb743c658b3dfc9b4befa719b595ac8b1b8cac4 passed generation/build,
870 Swift tests/132 suites and20 XCTest in PR37174200703 / phone111353318751
and push37174198078 / phone111353307980. Both complete phone runs executed
45 UI cases with1 expected Pad-only skip and8 assertions in4 Sidebar positive
cases; prior UI cases passed. This is not a completed Sidebar gate.

PR actual Pad111353318723 passed103.295s: real Pan85.5pt, width688→773.5.
Push Pad111353307992 failed initial owner/orientation readiness and the
width assertion after real Pan29.5pt (width688→717.5), with earlier Simulator
service-hub interruptions also recorded. Source review found no direct Sidebar
touch admission in Split: nil context rejects each recognizer. Keep the failed
assertions. The next test choreography observes stable prerequisites and each
owner lease separately; the same100pt drag uses slow XCTest delivery while the
>50pt width assertion and all ratio/identity/geometry checks remain. No retries,
sleep-based readiness or higher timeout. Reviewed without a weakened assertion.
Apple API: https://developer.apple.com/documentation/xcuiautomation/xcuicoordinate/press(forduration:thendragto:withvelocity:thenholdforduration:)

The native cause of stable-editing admission was identified: Lift's native
settled phase deliberately requires resting, so Sidebar could never accept a
stable editing Composer. Sidebar now uses its own phase predicate (resting or
editing), sharing the actual geometry/composition/keyboard inputs while keeping
Lift's resting-only predicate. An existing-API native host regression covers
both stable phases. Bounded DEBUG native touch/gesture receipts and native
opening readiness observations diagnose the remaining landscape/tap failures.
The fixed sidebar-red profile temporarily selects all units and Sidebar UI;
another complete product run is still required before S5-13.

### Stable editing receipt and remaining gesture arbitration

Remote402d957c6d8a951982f651b90c2ee0d395dc78ec / tree
6e578d2e56bb9c770b380b1411c6dd9ac6c120a8 targeted PR37176177904 /
phone111359151630 and push37176175330 / phone111359148606 passed
XcodeGen/build,871 Swift tests/132 suites and20 XCTest. Both native stable-phase
cases passed. The actual stable-editing edge/reverse UI case now passed in both
runs; both negative Sidebar cases passed. Six assertions remain in three UI
cases: landscape opening and two Surface-tap close cases, with later normal
keyboard dismissal blocked because the failed close leaves the Rail open.
Actual Pad111359151672(PR)/111359148603(push) both passed, observing81pt
and85.5pt Pan respectively. These targeted runs do not close the full gate.

Both phone traces admit the landscape edge at(1,160.67) inside an actual
(0,0,874,402) anchor with native opening=true, but show no begin callback.
Both shifted-tap traces pass Surface ancestry and reach shouldBegin without an
ended callback. The next correction uses UIKit's dynamic failure dependency
to prioritize an eligible edge over content recognizers and an open-Surface
tap over recognizers within that Surface. Own reverse/edge/tap recognizers,
other native screen-edge gestures and Rail controls are excluded. Existing
reverse failure dependency remains. A native delegate-policy regression checks
these bounds; actual UI remains the behavioral gate. Tap admission is also
recorded explicitly to distinguish owner rejection from recognition competition.
Current Apple reference: https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate

### Tap arbitration receipt and unobstructed landscape edge

Remotef1e08f3997cf780ade06f44dda321cd872110a5b / tree
9176c7f3140060000c6c637ff81e1666e74eebd5 targeted PR37176997449 /
phone111361619775 and push37176995492 / phone111361612248 built and ran
872 Swift tests/132 suites with one issue: the new policy fixture selected
UIWindow's built-in keyboard-dismissal tap rather than this module's tap.
The fixture now selects recognizers whose delegate is the interaction owner.
20 XCTest passed. Both runs' two Surface-tap UI cases now pass with actual
tap ended callbacks, retained focus/draft and a later normal blank dismissal.
Stable editing/reverse and both negative cases pass. Only the landscape opening
assertion remains in the six Sidebar UI cases; no failed expectation is erased.

PR actual Pad111361619935 passed100.981s, actual Pan72pt. Push actual
Pad111361612042 failed to find split-open-top after the toolbar tap, before
any axis behavior. Earlier app launch/AX delays remain observations, not a
blanket infrastructure classification. Edge failure priority is now additionally
gated by this touch's actual leading-window origin and same host/Pane/window,
within the Rail travel corridor. UIScreenEdgePan still owns its native edge
activation radius; this is a bound on priority, not a new recognition threshold.
New touches, owner/window changes and terminal callbacks clear the candidate.

The PR failure xcresult artifact11292859584 was downloaded and its landscape
screen recording inspected. Its sensor island aligns with the former edge
touch's vertical region (window point1,160.67). Native traces show neither an
edge begin nor priority queries there; attributing that to content competition
alone was unsupported. The next UI choreography starts at the unobstructed
leading edge at25% height and separately exercises the opposite landscape
orientation. It retains the same110pt drag, native width/editor identity checks
and real tap-close assertions; it adds no retry or larger timeout. The sensor
alignment is an observation, not a claim about UIKit's undocumented cutoff.
Current edge orientation documentation states that edges are relative to the
current interface orientation; no manual coordinate rotation or edge remapping
is introduced: https://developer.apple.com/documentation/uikit/uiscreenedgepangesturerecognizer/edges

### Current geometry lifecycle correction

Remote9a99901385ea9bbfcd32282ea9912b743c3b3169 / tree
b211745f364bfac5ac4426a1510d222a5b2a7e08 targeted PR37177952963 /
phone111364457555 and push37177951403 / phone111364449306 passed
872 Swift tests/132 suites and20 XCTest. Both completed seven Sidebar UI cases:
five passed; both independent landscape orientations failed only the opening
assertion. Moving outside the observed sensor corridor did not resolve it, so
the corridor alone is not the demonstrated cause. No native begin or priority
query appears at either clear-edge point. Prior failed observations remain.

Push actual Pad111364449267 passed110.570s with85.5pt Pan. PR actual
Pad111364457509 failed its initial source.exists expectation; the first AX call
took about9 seconds with internal lookup retries within the10-second predicate
deadline. Later axis/resize/ratio/editor checks passed, with actual81pt Pan.
Initial owner existence now uses XCTest's dedicated waitForExistence with the
same10-second bound and assertions; no added application retry or larger wait.
API: https://developer.apple.com/documentation/xcuiautomation/xcuielement/waitforexistence(timeout:)

The native gesture adapter previously retained its initial Window attachment
across scene geometry changes. The next correction snapshots actual Window
bounds and scene.effectiveGeometry.interfaceOrientation and reattaches the owned
recognizers when those change. It clears captured touch/gesture ownership and
cancels old navigation. Anchor-only keyboard resizing preserves attachment.
A real UIWindow/anchor geometry regression checks cancellation, keyboard
preservation and retained recognizer identities. DEBUG attachment receipts show
the actual geometry. This lifecycle correction still requires actual landscape
UI results; it does not assert an undocumented UIKit caching guarantee.
Scene API: https://developer.apple.com/documentation/uikit/uiwindowscene/effectivegeometry

The iPad test also awaits the actual Split menu item (10 seconds) before tapping it; absence fails at that prerequisite rather than issuing input against a missing AX element.

### Scene root edge transport — candidate, not a completed gate

Remote `65bc329793dd040449f921a85ca0a2b1d9b059a5`, exact tree
`1e3758147cb958fde67b8dabd6c7c9572a1e422c`, PR CI37179082216:
generation/build,873 Swift tests/132 suites and20 XCTest passed. Push
CI37179080333/phone111367791714 independently passed the same units. Seven Sidebar
UI cases still failed only the two landscape openings. Actual native receipts
show reattachment at874×402 and effective interface orientations3/4 before
admitted touches atx1,y100; neither produced an edge begin/callback. This rules
out missing reattachment as a sufficient explanation. Both actual iPad jobs
passed (PR111367809254:88.396s; push111367791665:125.919s), actual Pan85.5pt.

Next bounded correction attaches the native screen-edge recognizer to the
mounted scene root content view rather than UIWindow. Window/Pane identity,
admission and movement measurements remain authoritative; the independently
passing reverse/tap transports stay on Window. Lifecycle tracks root identity
and bounds alongside actual scene geometry and removes each recognizer from
its own attachment. The native unit regression verifies these attachments,
keyboard-only preservation, real bounds-change cancellation and identity reuse.
The two landscape behavior tests remain unchanged. This is a candidate to
verify, not a claim that Apple's recognizer has a platform defect.

### Targeted GREEN; full product gate pending

Local `7ffdc14` /remote `b6ba4473b23bbd738f5c02ce414df893eba2af9a` /
tree `e4e713dd7176ad601c93d40e1a3f6b1011007d04` passed source review.
PR37179904319/phone111370197952 and push37179902790/phone111370192950
both generated/built the project and passed873 Swift tests/132 suites,20 XCTest
and all7 Sidebar UI cases. Both landscape openings now have actual edge begin,
changed and ended callbacks and open=true/progress=1/settlement=nil; inner
Timeline/editor widths and identity assertions passed. Other five cases passed.
No test host restart/retry.

Actual PR Pad111370197898 passed147.463s with native Pan81pt. Push
Pad111370192983 failed78.892s: Xcode timed out launching the application,
before any axis assertion or Pan. This job is unavailable acceptance evidence,
not a passed test or an observed axis behavior regression.

The temporary Sidebar profile is now removed. The next publication runs the
complete product unit/UI targets and the dedicated actual Pad job. This record
does not close S5-12 until that full gate has a real completed result.

### Full code gate — passed; physical acceptance open

Local `d89aa12` /remote `9218e8c7fc9e5a11baa53bafda4787fb962768c0` /
tree `6c1b9095f933b111590025a6d0aadd9a6bfe3bd1` has no temporary test profile.
PR37180642485/phone111372446239 and push37180640443/phone111372360937
both passed hygiene, XcodeGen generation, app build,873 Swift tests/132 suites,
20 XCTest and46 phone UI cases with one expected Pad-only skip and zero failures.
All seven Sidebar and39 previous product cases passed. Each log has one Swift
Testing run start; neither test host restarted and no test retry was used.

Both dedicated actual Pad cases passed: PR111372446286,153.133s,Pan85.5pt;
push111372360985,179.639s,Pan81pt. Native width changed beyond50pt; separate
axes/ratios and both editor identities/leases were retained.

This closes the S5-12 code gate and permits S5-13 in dependency order. PR#29 is
still draft/open/unmerged on S5-11; no main merge, IPA or physical acceptance is
included. Device edge/system navigation, VoiceOver and comfort remain for the
owner's later pass. This closure is carried by the subsequent Search test-only
publication; the exact tested predecessor tree above remains the build receipt.
