# Dark Split Sidebar divider fade — 2026-10-21

User device feedback: the dark Split gutter and handle remain visible with the Sidebar open. Existing isolated handle color coverage does not establish the complete composited result.

Correction: the dark-only gray gutter explicitly fades with Sidebar progress. The native handle decoration also fades to zero at fully open, keeping the native resize UIView, gesture ownership, bounds and accessibility intact. Light appearance, pane outlines, card shadows and Composer are unchanged. This implements the existing seam-disappearance intent; no new runtime boundary or ADR is introduced.

- App source: `9ba857e112f4f839d1fad8e0eae2cedb9a71baee`.
- Packaging source: `811824edac848813aef4ddc85e1c01296f76196b`; frozen-source tree comparison passed. Packaging workflow differences only.
- Build/package: https://github.com/54zhien/Zen-Agent/actions/runs/39527807528 — success. XcodeGen and actual unsigned arm64 iOS device build passed.
- IPA version `15.1`, SHA256 `5564033f104ba5465d3b8575a4f4eaa6b030960692c150728a4e9ab9a53ed622`. Downloaded hash and bundle version/source receipt checked.
- Per the user's standing no-test delivery instruction, no test suites or simulator visual capture ran. Physical device visual acceptance remains pending.
- Setup run 39527790569 was cancelled when the packaging guard was corrected to compare the cherry-picked source tree rather than require source ancestry. It is not passing evidence.
