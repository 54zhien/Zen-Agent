# Stage 9: MCP completion

**Final receipt date:** 2026-10-30 (Asia/Shanghai)

**Status:** Implementation and full native CI gate complete in draft PR #46; not merged.

- PR: [#46, Stage 9: Complete MCP integration](https://github.com/54zhien/Zen-Agent/pull/46)
- Branch: `codex/stage9-mcp-completion`
- Base: `codex/stage9-mcp-registry` at `9e1e5f7fc5b58406635a417d4bbd27c8f3cb4171`
- Tested source SHA: `94ca4306f1b2de0f13caa289538ad37d6913af0a`
- Tested source and PR merge tree: `f34dd3aa25a8d6305e74dc97769c86d1fc9815fa`
- Worktree: `C:\Users\Azusa\.codex\worktrees\stage9-mcp-completion\Zen-Agent`
- Detailed implementation plan: [2026-10-29-stage9-mcp-completion.md](../Docs/superpowers/plans/2026-10-29-stage9-mcp-completion.md)

## Delivered scope

- Persist MCP server configuration and non-secret references to the existing CredentialStore or explicit Global Environment secrets. Secret bytes and negotiated session/connection state remain transient.
- Support Streamable HTTP for modern MCP `2026-07-28` and legacy `2025-11-25`, including capability-aware paginated Tools, Resources, and Prompts discovery, Tool calls, cancellation, reconnect, and legacy session invalidation after 404 without replaying a dispatched call.
- Add connected MCP Tools to the existing shared ToolRegistry and ToolPolicy with stable namespaced IDs, explicit approval, versioned endpoint/auth/descriptor identity, frozen Run and Skill dependencies, and no retargeting after Settings changes.
- Wire server reconnection through the existing AppShell/Workspace lifecycle and cold-start recovery paths.
- Add the approved native Settings → Agent → MCP list/detail Form, existing-credential selection, shared Tool Policy entry, and XcodeGen local-network usage/ATS configuration.

Resources and Prompts are discovered and listed only; this stage does not read resources or inject prompts. Authentication uses existing secret references as Bearer credentials; OAuth, DCR, browser login, MCP-specific environment overlays, deprecated HTTP+SSE, and unverified legacy protocol revisions are not claimed as supported.

## Final native CI evidence

The complete [PR CI run 40938534164](https://github.com/54zhien/Zen-Agent/actions/runs/40938534164) passed on tested source SHA `94ca4306f1b2de0f13caa289538ad37d6913af0a`. Repo hygiene, XcodeGen generation, app build, unit tests, Phone UI tests, and the independent iPad axis job all succeeded. The source commit and PR synthetic merge tree were identical.

- Swift Testing: 1,336 tests in 226 suites passed.
- XCTest unit target: 20 tests, zero failures.
- Phone UI target: 98 tests, one expected Pad-only skip, zero failures.
- MCP Settings UI case `testServerConfigurationUsesExistingCredentialReferenceAndSharedToolPolicy`: passed in 70.374 seconds.
- iPad axis case `testNativeAxisMenuPreservesBothEditorsAndSeparateRatios`: passed, one test, zero failures.
- The previously failing unreadable-pending-intent parameterized case passed all six cases. Both previously failing ToolIntentVersion cases passed. The MCP policy and Skill snapshot cases were part of the fully passing 1,336-test unit run.

Physical-device Local Network permission, configured LAN HTTP, and real foreground/background recovery remain unverified; the simulator and CI do not establish those device acceptances.

## Preserved failure and cancellation provenance

Earlier red runs are retained with their original results: `40888457106` (missing `try`), `40889153484` (AppAssembly argument order), `40890599930` (missing getter return and SwiftUI escaping closure), `40892045797` (XCTest `#require` argument evaluation), and `40894848038` (the eight unit issues plus the first MCP UI failure). Each source error was corrected from its recorded compiler or test evidence without adding tests, skips, or broadened assertions.

Run `40909385002` retained the MCP UI failure evidence: the test step failed on two assertions because the state AX label was `状态, 未连接` and the delete confirmation exposed two nested buttons with the same accessibility identifier. The Build and test job later ended cancelled after exceeding its 85-minute budget during evidence export. The exact label assertion and scoped unique confirmation query fixed those two findings in commit `3f7f65d9dfacbe0d14417138250db3161022db27`.

Run `40924690416` on source `3f7f65d9dfacbe0d14417138250db3161022db27` passed all test steps, including 1,336/226 Swift Testing, 20 XCTest, and 98 Phone UI tests with one skip and zero failures. The overall job was nevertheless cancelled after 86m02 because its Build and test timeout was 85 minutes; test evidence upload completed. Commit `94ca4306f1b2de0f13caa289538ad37d6913af0a` changes only that job’s timeout from 85 to 95 minutes, and final full gate `40938534164` succeeded with the same suite. The timeout adjustment did not change build inputs, test selection, commands, retries, skips, or other jobs.

Same-tree push runs `40924680805` and `40938525661` were cancelled as duplicates only after verifying the source and PR merge trees matched. The earlier red runs and timeout-cancelled run remain visible and are not reclassified as successful gates.

This receipt and README are a documentation-only update after tested source `94ca4306f1b2de0f13caa289538ad37d6913af0a`; App, Tests, `project.yml`, `Config`, Resources, and the CI workflow remain unchanged from that tested source. PR #46 remains draft/open and stacked on the unmerged registry branch. The final documentation-only tip and its build-input equivalence are recorded in the PR receipt. No merge to `main` or IPA build was performed.
