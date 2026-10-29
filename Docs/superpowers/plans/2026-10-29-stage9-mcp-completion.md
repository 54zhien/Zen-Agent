# Stage 9 MCP Completion Plan

> Execute inline in the assigned worktree; blueprint_gate performs an independent review of completed modules.

**Goal:** Complete the approved MCP product path: configure servers, discover capabilities over supported Streamable HTTP, route MCP Tools through the existing ToolPolicy, and manage them in Settings.

**Architecture:** Keep persisted server configuration in the existing MCP registry and keep connection/session state in an in-memory MCP runtime. Negotiate modern 2026-07-28 or legacy 2025-11-25 Streamable HTTP according to the audited protocol rules. Build namespaced, revisioned MCP Tool descriptors into the existing ToolRegistry and leave authorization, dispatch, cancellation settlement, and crash recovery with ToolRuntime and ToolPolicy.

**Tech Stack:** Swift 6, URLSessionHTTPTransport/HTTPStream, GRDB, SwiftUI Form, XcodeGen, existing Keychain credential and Environment runtimes.

**Spec:** Blueprint Design/Zen Agent 开发规划.md Stage 9; Design/Zen Agent Agent 能力与扩展.md MCP and Settings sections; Design/Zen Agent Tool Runtime.md; Design/Zen Agent 安全与权限.md.

## Global Constraints

- Support only modern MCP 2026-07-28 and legacy Streamable HTTP 2025-11-25; do not implement deprecated 2024 HTTP+SSE or claim unverified earlier 2025 revisions.
- Follow blueprint_gate's official method, header, body, discovery, fallback, and cancellation mapping exactly; do not retry an MCP tool call after dispatch.
- Persist configuration and credential references only. Auth is a selected CredentialStore reference or an explicit Global Environment secret reference, resolved as Bearer at request time; no OAuth, DCR, browser login, MCP variable overrides, or Skill Environment inheritance. Never persist secret bytes, negotiated protocol, session IDs, connected state, or transient errors.
- MCP Tools use the existing ToolRegistry, ToolRuntime, execution snapshot, and ToolPolicyEngine. Resource/Prompt discovery is display-only in this stage.
- Use the approved Settings → Agent → MCP Form flow. Keep all other Settings, Composer, and Sidebar behavior unchanged.
- Use XcodeGen project.yml as the Info.plist source. Add NSLocalNetworkUsageDescription and NSAllowsLocalNetworking; do not enable arbitrary HTTP.
- Add product acceptance tests for protocol negotiation, restart-safe server configuration, capability presentation, ToolPolicy dispatch, and the approved Settings flow. Do not add defensive-only tests or code.

## Work Packages

### 1. MCP client and connection runtime
**Files:** App/MCP/**; App/Persistence/MCPServerRecord.swift, PersistenceStore+MCPServers.swift, Migrations.swift, Migrations+Extensions.swift; App/AppShell/AppAssembly.swift; project.yml; MCP product tests.
- Add modern/legacy Streamable HTTP request negotiation and protocol response decoding on the existing HTTP transport.
- Own transient connection state and paginated capability catalog; connect/disconnect/cancel/reconnect act on the configured server without persisting protocol/session state. Handle actual iOS suspend/foreground recovery without promising unlimited background execution.
- Persist a selected credential reference and resolve secret bytes through CredentialStoring; do not place secrets in SQLite or diagnostics.
- Verify supported modern discovery, legacy negotiation only on the specified compatibility responses, tool/resource/prompt discovery when advertised, and clean restart behavior.

### 2. MCP Tool catalog through the existing runtime
**Files:** MCP runtime plus the authorized existing App/Tool/** and App/Runtime/** MCP seams; focused MCP/ToolPolicy/Runtime tests.
- Create namespaced stable IDs; revision fingerprints include the server identity, endpoint, and discovered Tool definition. Freeze the executor and version with each Run so later Settings edits cannot redirect an older Run.
- Expose the discovered Tool snapshot to providers and resolve execution against that same descriptor revision.
- Use the existing frozen run snapshot and transactional ToolPolicy admission. Cancellation before dispatch prevents the call; after dispatch, preserve existing durable uncertain-call recovery without replay.
- Verify an MCP Tool reaches the normal shared policy/approval path and a definition change does not reuse the prior descriptor grant.

### 3. Settings product closure
**Files:** App/Settings/** only for MCP and existing Tool Policy navigation; Tests/ZenAgentUITests/*MCP*.swift plus required host wiring; README.md; tasks/stage9-mcp-completion.md.
- Add the approved MCP server list and detail Forms with name, endpoint, credential reference, enabled/connection state, last error, capability counts and Tools/Resources/Prompts lists, connect controls, policy entry, and delete.
- Keep Resources and Prompts display-only. Add the approved ATS/local-network usage properties through XcodeGen.
- Verify the product configuration and capability flow in UI tests; record source SHA, full CI results, and physical-device/LAN acceptance separately.

## Validation

Run the assigned local static checks, then the normal complete CI once for the finished Stage 9 source. Use actual CI results to repair failures. Physical LAN permission acceptance is a separate device result and must not be inferred from simulator or CI evidence.

## Shared worktree ownership

- `repo_gate` owns `App/MCP/**` except `MCPToolExecutable.swift`, the MCP persistence migration/registry paths, AppShell assembly/model and existing Workspace lifecycle hook, `project.yml`, and MCP backend tests.
- `blueprint_gate` owns the MCP Tool and Runtime integrations, `MCPToolExecutable.swift`, MCP Settings UI paths, and MCP UI tests. Both owners work in this assigned worktree; `repo_gate` performs the final allowlist commit and push.
- App launch reconnects enabled MCP servers before cold-start Run reconciliation. Foreground recovery uses the existing scene-phase observer; no second lifecycle observer is introduced.
