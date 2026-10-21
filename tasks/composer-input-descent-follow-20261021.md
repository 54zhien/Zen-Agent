# Composer follows input sheet descent — 2026-10-21

Owner device feedback on 41.1: the sheet now exits correctly, but Composer jumps. Blueprint b6cf5db. Preserve the accepted sheet and shape animations; compile/package only, no tests.

Cause verified in source: non-restoring close retained a constant reservedTop through presenter.dismiss, then finish set it to nil and the Host immediately laid out its native keyboard constraint. No continuous anchor movement existed.

Plan and ownership: ComposerInputDescentTracking reads the existing primary/detail sheet presentation-layer translation using a weak display-link proxy. Session maps that progress from the held reservation to its same-window root keyboard layout guide, publishing both native Composer and SwiftUI viewport updates. The actual sheet remains the timing owner. Completion publishes the exact native endpoint before removing the override. The Host updates only the bottom constraint during these frame updates, preserving the independent shape transition rather than rerendering its endpoint on every viewport resize.

Only non-restoring animated user close starts tracking; ordinary plus-to-keyboard and detail-to-parent paths are unchanged. Repeated close does not restart tracking. Completion, background teardown, invalid attachment, suppression and immediate close cancel tracking; weak ownership prevents a display-link retention cycle. Reduce Motion uses the existing immediate path. No haptics, symbol, typing, model or thinking changes.

Static review and real macOS build pending. Unrelated deep-reading-native-trace.txt excluded. No tests and no main merge; actual device motion acceptance pending.

## Package receipt

Static review found no remaining actionable issues. Real macOS XcodeGen and unsigned device build succeeded: https://github.com/54zhien/Zen-Agent/actions/runs/39604143104 (package job 3m17s).

- Application source: 9fc420e8a685989beae057a1c36dea21715dc097.
- Packaging source: 8d01ad4e25336e8931805597c7ccab1e7463b056.
- Downloaded IPA version: 42.1; com.zhien.zen. Local provenance and SHA-256 matched.
- IPA: C:/Users/Azusa/Documents/Codex/artifacts/2026-10-21-composer-descent-follow/ZenAgent-Composer-device-ipa-42-1/ZenAgent-Composer-42-1.ipa.
- SHA-256: 7ade58ae2150164afa0baf5de7c995977d845173754467c6028d7172790faa8a.

No tests were run, no main merge. Device animation acceptance remains pending; compilation does not establish motion quality.
