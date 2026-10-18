# Test suite cleanup implementation plan

**Goal:** Remove tests that check Swift syntax, trivial storage, the compiler or test doubles instead of production behavior.

**Architecture:** Test-only cleanup; keep production code and user-facing behavior unchanged. Retain the actual Runtime, database, transport, editor and UI regressions. Blueprint authority: `Design/Zen Agent 工程与发布.md` §4 and `Design/CONTEXT.md`.

**Tech stack:** Swift Testing, XCTest, XcodeGen, macOS GitHub Actions; Windows has no local Swift compiler.

## Scope and ownership

The current agent owns only the named test removals, their now-unused private helpers, this audit record and the focused CI selection. Preserve the unrelated untracked native trace. Historical stage receipts and packaging provenance lists remain historical evidence.

- [x] Inventory all test targets and CI scripts; inspect source-scanning, constant-only, compile-only and plain-storage candidates against real callers and retained consumer tests.
- [x] Remove nine obsolete smoke/source/structure/storage suites. Preserve the IME update-policy behavior from the Composer contract suite in the existing text-projection suite. Remove compiler-only Sendable probes and redundant constant/trivial-constructor cases from otherwise useful suites.
- [x] Remove attachment declaration parsing/reflection and approval text-layout checks; preserve actual attachment ingestion, frozen approval disclosure, execution and owner isolation checks. Retain the unique approval handoff guard pending real UI coverage.
- [x] Add an explicit opt-in native maintenance selection for the retained affected suites. Existing full and keyboard/Sidebar selections retain their behavior. No archive, signing, export, full unit target or UI run.
- [ ] Check deleted test references, helpers, YAML and manifest consistency. Run XcodeGen, native build and the selected remaining tests in CI, with zero skipped tests and every selected suite present. Record exact source SHA and actual counts.

## Keep boundaries

Keep security/permission/identity, migration/transaction, streaming/cancellation/recovery, corrupted persisted input, finite native geometry, actual editor/IME, keyboard/Sidebar/Split and accessibility behavior tests. Invalid-input tests are not deletion candidates merely because they exercise failure.

Tests guarding approved typography policy by source spelling cannot prove the resulting font; retain actual bundled font, CoreText variation and Dynamic Type tests. Compilation and actual consumer tests supersede type-link and Sendable smoke probes.

## Audit decisions and local evidence

- Inventory: 209 Swift test/support files, 1,245 test declarations before cleanup; 200 files and 1,208 declarations afterward. These are declarations, not expanded parameterized-case counts or an execution result.
- Remove nine files: smoke (2 tests), Composer source discipline (4), typography source discipline (3), reading source discipline (2), Pane view structure (1), Composer view structure/policy (5), attachment storage/structure (3), selection storage/structure (3), and draft storage/copy (3). Relocate the one IME policy test unchanged apart from removing its source-text assertions. Net removal in these files: 25 declarations.
- Remove 12 other declarations: five compile-only Sendable probes, two FakeProvider-only capability probes, two Composer configuration stored-field probes, two exact typography token-table probes, and one reflected/source-parsed attachment shape probe. Existing meaningful tests in those suites remain.
- Tool approval keeps all 12 tests. Actual frozen Runtime projection fields replace the test-local string concatenation helper; approval execution/rejection and cross-owner isolation assertions remain. No actual UI regression, keyboard stress assertion or security guard was removed.
- Independent static review found the marked-text policy assertions alone do not prove native host integration. Strengthen the existing native host test: reconfigure during actual marked text, preserve text/selection/editor identity, then verify committed projection updates after unmarking.
- Review ruling: retain the existing approval Button→request→Timeline→Runtime handoff guard. It is the only wiring guard here and protects a concrete delivery failure. A real UI replacement would require a new harness outside this removal-only cleanup; do not claim runtime projection tests exercise actual card taps. Remove only its unrelated source-text/layout and test-local rendering checks.
- Mark the historical pending typography-gate task as superseded by this cleanup, preserving its original entry and the retained font runtime tests.
- Ruling: test-only removal does not add a failing production test merely to demonstrate deletion. Build all targets and execute the retained affected consumers instead; production `App/`, `Config/` and `project.yml` have no changes.
- Ruling: the old W1 packaging workflow lists changed paths relative to its historical baseline, not current files to open. Its historical Composer contract path remains valid as a deleted diff path; preserve that provenance check and historical task receipts.
- Local checks: YAML parsing, both focused shell scripts' syntax, deleted-helper/reference sweep and `git diff --check` passed. All 12 existing Python CI-profile guard tests passed. Sixteen retained Swift suites are explicitly selected for native verification (115 declarations); native execution is still required.

## Validation

Delete no product guard and weaken no real regression assertion. The cleanup is authorized by the user's request; execute it in this branch, then review the concrete diff and native results. Existing prior full-CI failures remain separate from this scoped cleanup result.
