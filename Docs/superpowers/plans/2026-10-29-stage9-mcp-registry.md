# S9-01 MCP Server Registry Implementation Plan

> Execute inline with superpowers:executing-plans; no worker delegation.

**Goal:** Persist manual MCP server configuration in the shared App runtime with restart-safe CRUD and truthful status.

**Architecture:** `MCPServerRegistry` owns configuration CRUD and derives connection status from `enabled`. `PersistenceStore` writes v25 configuration rows; `AppAssembly.Dependencies` exposes a registry backed by the app's existing store.

**Tech stack:** Swift 6, GRDB, existing AppAssembly/PersistenceStore, XcodeGen/macOS CI.

**Spec:** Blueprint `Design/Zen Agent 开发规划.md` Stage 9 and `Design/Zen Agent Agent 能力与扩展.md` §4 MCP. Transport audit is a later Stage 9 step.

**Base:** `99d7865dba8a647d6cdf56d57fd870d32dbe7881`; branch `codex/stage9-mcp-registry`.

## Global Constraints

- No UI, network transport, protocol/session state, capability discovery, Tool registration, ToolPolicy change, auth reference, or Environment scope change.
- Persist only server ID, display name, endpoint text as supplied, enabled state, and creation/update timestamps; new servers start disabled. Defer endpoint policy and input validation until the user-facing configuration flow and transport contract are approved.
- Derive status: disabled when disabled, disconnected when enabled. Do not persist connection, session, or protocol-version state.
- Leave CredentialStore/Keychain unchanged; no secret bytes enter this schema.
- Append v25 without editing v1-v24. Existing XcodeGen source globs include new files.
- Add only normal product coverage for CRUD, stable identity, reopen, and v24 upgrade. No defensive matrix or unrelated regressions.

## Review Focus

- Edit preserves stable server ID and latest configuration after reopen; covered by the CRUD path.
- Enabled means disconnected until a transport exists; disabled means disabled; covered by the same path.
- A v24 database opens after v25 and supports the persisted registry path; existing v21-to-current migration coverage verifies Conversation rows remain readable.

## Tasks

### Task 1: Product acceptance path
**Files:** Create `Tests/ZenAgentTests/MCPServerRegistryTests.swift`.
- [x] Test create/list/edit/enable-disable/delete and reopening through the real GRDB migration/store path.
- [x] Start at v24 and exercise the v25 registry through the production store; existing migration coverage retains the Conversation preservation assertion.
- [x] Windows Swift 6.4 syntax parsing passed; native build and acceptance ran in macOS CI.

### Task 2: Registry and persistence
**Files:** Create `App/MCP/MCPServer.swift`, `App/MCP/MCPServerRegistry.swift`, `App/Persistence/MCPServerRecord.swift`, `App/Persistence/PersistenceStore+MCPServers.swift`; modify `App/Persistence/Migrations+Extensions.swift`, `App/Persistence/Migrations.swift`.
- [x] Expose stable ID, display name, endpoint, enabled flag, timestamps, and derived disabled/disconnected status.
- [x] Add v25 and the minimum store/service operations required by the product test.
- [x] Defer endpoint protocol and content validation until the audited transport and approved configuration flow.

### Task 3: AppAssembly and evidence
**Files:** Modify `App/AppShell/AppAssembly.swift`; create `tasks/stage9-mcp-registry.md`; update this plan with validation.
- [x] Expose the registry from AppAssembly dependencies using the same store; add no UI consumer.
- [x] Run static checks and review the allowlisted diff; commit and push only this branch.
- [x] Record exact tested SHA, workflow URL/result, and failures without replacing prior evidence.

## Validation receipt

- Tested source SHA: `ec6f2ff58da717040e4ffd5c392de906d7d792c6`.
- [CI run 40860442852](https://github.com/54zhien/Zen-Agent/actions/runs/40860442852): all jobs passed; XcodeGen, app build, repo hygiene, and iPad axis passed.
- Swift Testing: 1,319 tests in 222 suites passed; `server configuration CRUD survives a v24 database reopening` passed in 0.118 seconds.
- XCTest: 20 unit tests passed; Phone UI suite executed 97 tests with 1 skip and 0 failures; the separate Pad axis test passed.
- Physical-device acceptance was not performed. The follow-up task/plan receipt is a documentation-only commit; it does not change build inputs.
