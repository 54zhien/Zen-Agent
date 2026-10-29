# Stage 9-01: MCP server registry

## Scope

Persist manual MCP server configuration and expose its CRUD registry from
`AppAssembly.Dependencies`, using the existing `PersistenceStore`. The v25 row
contains only ID, display name, endpoint text, enabled state, and timestamps.
Connection state is derived as `disabled` or `disconnected`; transport, session,
protocol, auth, environment, Tool registration, and UI remain later work.

## Implementation evidence

- Base: `99d7865dba8a647d6cdf56d57fd870d32dbe7881`
- Branch: `codex/stage9-mcp-registry`
- Worktree: `C:\Users\Azusa\.codex\worktrees\stage9-mcp-registry\Zen-Agent`
- Product path: v24 disk database upgrade, create/list/edit/enable/disable/delete,
  close/reopen, and stable ID/configuration recovery in
  `MCPServerRegistryTests`.
- Tested source SHA: `ec6f2ff58da717040e4ffd5c392de906d7d792c6`.
- Independent review: passed with no findings.
- Local checks: Swift 6.4 syntax parsing and `git diff --check` passed.

## CI receipt

[CI run 40860442852](https://github.com/54zhien/Zen-Agent/actions/runs/40860442852)
completed successfully on the tested source SHA. Repo hygiene, XcodeGen
generation, app build, Phone tests, and the separate iPad axis all passed.

- Swift Testing: 1,319 tests in 222 suites passed. The MCP registry CRUD,
  v24-upgrade, and reopen case passed in 0.118 seconds.
- XCTest unit tests: 20 passed, 0 failures.
- Phone UI tests: 97 executed, 1 skipped, 0 failures.
- iPad axis: `testNativeAxisMenuPreservesBothEditorsAndSeparateRatios` passed.
- Physical-device acceptance: not performed.

## Acceptance status

- Implementation and independent review: passed.
- Tested source SHA: `ec6f2ff58da717040e4ffd5c392de906d7d792c6`.
- Full CI: passed on the tested source SHA; the final receipt commit changes documentation only.
- Draft PR: [#45](https://github.com/54zhien/Zen-Agent/pull/45), base `codex/multi-round-tool-recovery-20261029`.
- Merge and device acceptance: not part of this implementation handoff.
