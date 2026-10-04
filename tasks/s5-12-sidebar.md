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
