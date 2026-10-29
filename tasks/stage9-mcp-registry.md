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
- Swift 6.4 syntax parsing and `git diff --check` pass on Windows. XcodeGen,
  iOS build, and native tests await the repository's macOS CI workflow.

## Acceptance status

- Implementation and allowlisted static review: passed; external review pending.
- Exact commit and remote branch SHA: pending.
- Full CI: pending.
- Merge and device acceptance: not part of this implementation handoff.
