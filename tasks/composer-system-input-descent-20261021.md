# System-animated Composer input descent — 2026-10-21

Owner reports package 42.1 is visibly choppy and approves trying the native-keyboard-style endpoint animation approach. Blueprint 883ae2a. Build/package only; no tests. Actual frame-rate cause has not been profiled on device.

Observed source cost: the previous CADisplayLink published menuTop to SwiftUI and forced native layout on every sheet sample. This task removes that follower entirely. Session sets its reservedTop to the same-window native keyboard guide once at user dismissal. ComposerInputAnimation publishes one animated SwiftUI viewport endpoint and adds the native constraint/layout update directly to the sheet's existing UIViewPropertyAnimator. Primary (.23 easeIn) and detail (.32 easeInOut) sheet animation parameters are unchanged. Only these built-in cubic timing curves are supplied to this helper.

Lifecycle ownership remains with Session/Presenter. Repeat close is idempotent. A blank tap during a keyboard-restoring dismissal changes destination by adding to the already-running animator; viewport timing uses remaining duration. Completion releases the override at the same native endpoint. Immediate cancellation, background, invalid attachment and Reduce Motion keep the existing cleanup path. The Host avoids replacing its independent shape animation as SwiftUI resizes the viewport. Ordinary plus-to-keyboard, detail return, haptics, symbols and other controls remain unchanged.

Apple API reference checked: https://developer.apple.com/documentation/uikit/uiviewpropertyanimator/addanimations(_:) documents adding blocks while running and their remaining duration. https://developer.apple.com/documentation/uikit/uicubictimingparameters/animationcurve documents built-in curve retrieval.

Static review/build pending. No main merge. Exclude unrelated deep-reading-native-trace.txt. Compilation cannot establish real-device smoothness; owner will evaluate the delivered build.
