# S5-12 Sidebar — preparation record

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
navigation wrapper owns Rail/overlay composition; a native adapter owns UIWindow
recognizer installation, arbitration and removal. Runtime owns Runs; the existing
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
