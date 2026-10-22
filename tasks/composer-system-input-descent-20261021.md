# System-animated Composer input descent — 2026-10-21

Owner reports package 42.1 is visibly choppy and approves trying the native-keyboard-style endpoint animation approach. Blueprint 883ae2a. Build/package only; no tests. Actual frame-rate cause has not been profiled on device.

Observed source cost: the previous CADisplayLink published menuTop to SwiftUI and forced native layout on every sheet sample. This task removes that follower entirely. Session sets its reservedTop to the same-window native keyboard guide once at user dismissal. ComposerInputAnimation publishes one animated SwiftUI viewport endpoint and adds the native constraint/layout update directly to the sheet's existing UIViewPropertyAnimator. Primary (.23 easeIn) and detail (.32 easeInOut) sheet animation parameters are unchanged. Only these built-in cubic timing curves are supplied to this helper.

Lifecycle ownership remains with Session/Presenter. Repeat close is idempotent. A blank tap during a keyboard-restoring dismissal changes destination by adding to the already-running animator; viewport timing uses remaining duration. Completion releases the override at the same native endpoint. Immediate cancellation, background, invalid attachment and Reduce Motion keep the existing cleanup path. The Host avoids replacing its independent shape animation as SwiftUI resizes the viewport. Ordinary plus-to-keyboard, detail return, haptics, symbols and other controls remain unchanged.

Apple API reference checked: https://developer.apple.com/documentation/uikit/uiviewpropertyanimator/addanimations(_:) documents adding blocks while running and their remaining duration. https://developer.apple.com/documentation/uikit/uicubictimingparameters/animationcurve documents built-in curve retrieval.

Static review/build pending. No main merge. Exclude unrelated deep-reading-native-trace.txt. Compilation cannot establish real-device smoothness; owner will evaluate the delivered build.

## Package receipt

Static review found no actionable issues. macOS XcodeGen and real unsigned device build succeeded: https://github.com/54zhien/Zen-Agent/actions/runs/39606551682 (package job 2m56s).

- Application source: 57f4edf3cd984b2f60646c05a1c9919747e356b8.
- Packaging source: 0c0fbad1c00368c3660d4f9be63e1fa82c5a1e13.
- Downloaded IPA version: 43.1; com.zhien.zen. Provenance and local SHA-256 matched.
- IPA: C:/Users/Azusa/Documents/Codex/artifacts/2026-10-21-system-composer-descent/ZenAgent-Composer-device-ipa-43-1/ZenAgent-Composer-43-1.ipa.
- SHA-256: bae7bdd758f8c14f9288193bb1ef64785fb4883dc576cf4c315b80ab7f397dc4.

No tests and no main merge. Actual device animation smoothness remains pending owner review.
