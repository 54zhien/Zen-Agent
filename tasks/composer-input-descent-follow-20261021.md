# Composer follows input sheet descent — 2026-10-21

Owner device feedback on 41.1: the sheet now exits correctly, but Composer jumps. Blueprint b6cf5db. Preserve the accepted sheet and shape animations; compile/package only, no tests.

Cause verified in source: non-restoring close retained a constant reservedTop through presenter.dismiss, then finish set it to nil and the Host immediately laid out its native keyboard constraint. No continuous anchor movement existed.

Plan and ownership: ComposerInputDescentTracking reads the existing primary/detail sheet presentation-layer translation using a weak display-link proxy. Session maps that progress from the held reservation to its same-window root keyboard layout guide, publishing both native Composer and SwiftUI viewport updates. The actual sheet remains the timing owner. Completion publishes the exact native endpoint before removing the override. The Host updates only the bottom constraint during these frame updates, preserving the independent shape transition rather than rerendering its endpoint on every viewport resize.

Only non-restoring animated user close starts tracking; ordinary plus-to-keyboard and detail-to-parent paths are unchanged. Repeated close does not restart tracking. Completion, background teardown, invalid attachment, suppression and immediate close cancel tracking; weak ownership prevents a display-link retention cycle. Reduce Motion uses the existing immediate path. No haptics, symbol, typing, model or thinking changes.

Static review and real macOS build pending. Unrelated deep-reading-native-trace.txt excluded. No tests and no main merge; actual device motion acceptance pending.
