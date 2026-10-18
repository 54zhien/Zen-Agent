# Restore omitted UI branch in device candidate

> Execute inline with superpowers:executing-plans; review the complete integrated diff once before native validation and packaging.

**Goal:** Restore the earlier UI polish omitted from the device package while retaining this chat's newer Sidebar, Lift and keyboard repairs.

**Architecture:** Merge `ui/polish-haptics-split-cards` at `5934dd0` into a repair branch based on `21570f3`. Preserve the existing mounted Surface/Composer owners, native reading capture, single keyboard avoidance boundary and horizontal Sidebar transport. No main integration.

**Spec:** Blueprint navigation note plus the owner's newer requests in this chat; the newer requests override older UI calibration (free Lift travel, smaller local corner radius, no Sidebar Split action, grouped bubble/search/history controls and tap feedback).

**Tech stack:** SwiftUI/UIKit, XcodeGen, focused macOS GitHub Actions, unsigned Debug device IPA.

## Evidence and constraints

- Wrong delivered candidate: frozen source `21570f3`, package `57e955d`, run `39116478910`, IPA SHA-256 `52fc35073bdaf5df0e51776dd514add490909a745dfe2f608c323edb08b4f944`.
- `5934dd0` is not an ancestor of that candidate. The shared ancestor is `341f7ab`. UI polish remains intact in its clean worktree.
- The test cleanup changed no `App/`, `Config/`, `Resources/` or `project.yml`; it did not delete the missing production UI.
- Keep the old package and failed validation provenance. Keep the unrelated trace. Do not run full tests, merge main, or overwrite another worktree.

## Work

- [x] Trace package provenance and establish the missing UI ancestry; reproduce the omission with `git merge-base --is-ancestor 5934dd0 21570f3` (fails).
- [ ] Resolve integration conflicts: restore card stack, display-concentric Split corners, haptics and native outline lifecycle; preserve newer Sidebar controls, exterior shadow mask, Lift travel and keyboard/reading repairs.
- [ ] Inspect automatically merged native geometry and UI fixtures; adapt only contradictory expectations to the combined behavior. Keep deleted low-value tests deleted.
- [ ] Review the complete integration. Run XcodeGen/build and focused UI/keyboard/Sidebar/native geometry tests only; preserve real failures and repair them.
- [ ] Build a new frozen-source device package, download it, verify hashes/plist/Mach-O/icons and identify the replacement to the owner.

## Review focus

Old Sidebar Split actions must not return. Lower picker corners and exterior shadows must agree. Native keyboard viewport/capture ownership and Sidebar horizontal transport must survive all corner/shadow signature changes. UI tests must enter Split through real drags after removal of Sidebar entry. Bare-layer dock outlines must retain the prior Files/rotation fix.

## Ledger

- Ruling: integrate on a fresh repair branch, not main or the UI worktree. A direct checkout of the older UI branch would discard newer keyboard/reading repairs, so resolve both sides explicitly.
