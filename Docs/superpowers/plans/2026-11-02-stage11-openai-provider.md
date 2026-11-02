# Stage 11 OpenAI Provider Implementation Plan

- Date: 2026-11-02
- Status: implementation complete; awaiting CI
- Base: `4277ec0ba6ef27c67397b0532125ba3e836cf9be`
- Branch: `codex/stage11-openai-provider`
- Worktree: `C:\Users\Azusa\.codex\worktrees\stage11-openai\Zen-Agent`

## Intent and constraints

Add an OpenAI model-level Responses API adapter and route DeepSeek and OpenAI instances through the current `ModelProvider` / Agent Runtime boundary. Zen keeps the conversation loop, durable Run state, ToolPolicy, approval, child lifecycle, and recovery. No subscription/OAuth, hosted agent, rich content, or unrelated providers/tools are in scope.

The second public provider is an abstraction check, not a second runtime. Use only the explicitly assigned paths:

- Add `App/Provider/ModelProviderRegistry.swift` and `App/Provider/OpenAI/**`; update `App/Provider/ProviderTypes.swift`.
- Update `App/Runtime/AgentRuntime.swift`, `ConversationRuntime.swift`, `RunRequestRebuilder.swift`, and `DelegationRuntime.swift`.
- Update `App/AppShell/AppAssembly.swift`, `AppShellConfiguration.swift`, `AppShellModel.swift`, `ConversationPaneFactory.swift`, `ProviderSetupView.swift`, `App/Settings/SettingsWorkspaceModel.swift`, `SubagentSettingsModel.swift`, and `SettingsProviderViews.swift`.
- Add `Tests/ZenAgentTests/OpenAIProviderTests.swift`, `OpenAIStreamingTests.swift`, `ModelProviderRegistryTests.swift`, and `MultiProviderRuntimeTests.swift`. Update only the specifically authorized existing tests if wiring requires it.
- Add this plan and `tasks/stage11-openai-provider.md`.

XcodeGen already includes the complete App and test directories, so this slice needs no project-file edit.

## Ownership, frozen identity, failure, and recovery

- A new Send resolves the Provider adapter from the selected `ProviderInstance.providerID`. The adapter owns provider request encoding, endpoint selection, SSE event decoding, and mapping complete function calls to the provider-neutral response types.
- At Run creation, `RunExecutionSnapshot.providerID` and `providerAdapterRevision` freeze the exact adapter identity and `PromptExecutionSnapshot.providerAdapterInstructions` freezes its prompt contribution. `RequestConfigSeed` already freezes instance ID, model, configuration revision, credential binding, and full endpoint. Reuse these fields; do not add a Provider ID to the seed or change persisted schema.
- Every active, recovered, and delegated Child request resolves by the Run snapshot's exact Provider ID and adapter revision. The stored instance Provider ID must agree with the frozen identity. An unknown Provider, missing adapter, ID mismatch, or revision mismatch fails explicitly; it must never choose DeepSeek (or another default).
- AgentRuntime continues to own Run and tool-call transitions, policy, approval, and dispatch. OpenAI function calls become the same ordered `ProviderToolCall` values used by DeepSeek; all complete calls pass through the existing ToolPolicy path. Function results are encoded with the original OpenAI `call_id`.
- Responses `output_index` identifies an output item in the whole response, and argument completion can arrive out of order. AgentRuntime sorts complete calls by that index and normalizes them to the contiguous batch sequence the durable tool transcript records.
- Cancellation remains owned by AgentRuntime and propagates through the provider AsyncThrowingStream to `HTTPStream.cancel()`. The OpenAI adapter does not retry POST requests. An interrupted stream carries whether text output was delivered; a partial answer is never blindly replayed. Existing Run recovery remains authoritative.
- Follow-parent Child Runs keep the frozen parent Provider and seed. An explicit child target is resolved and frozen from its own instance and adapter, including its adapter prompt instructions; recovery checks that same provider/revision binding. A missing or revised adapter leaves the Child explicitly unavailable rather than switching models.
- The settings flow chooses a Provider when adding an account, saves the corresponding Provider ID in the instance, and uses the registry for model listings, default validation, conversation configuration, and explicit Child model selection.

## OpenAI protocol and model choice

Current OpenAI first-party docs were checked for the Responses API, semantic streaming events, function calls, and model support:

- [GPT-6.1 Terra model](https://developers.openai.com/api/docs/models/gpt-6.1-terra)
- [Responses streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses)
- [Function calling guide](https://developers.openai.com/api/docs/guides/function-calling)
- [Responses create reference](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [Responses streaming event reference](https://developers.openai.com/api/reference/resources/responses/streaming-events)
- [Reasoning guide](https://developers.openai.com/api/docs/guides/reasoning)

Use `gpt-6.1-terra`, whose current model page lists Responses, streaming, and function-calling support. The provider uses `POST /v1/responses`, semantic SSE events including `response.output_text.delta`, `response.completed`, function-call item/delta/done events, and each function output's matching `call_id`. Parallel calls are accumulated independently and emitted only when complete.

Set `reasoning.effort` to `none` and `store` to false. The model documents effort `none`; this avoids depending on opaque reasoning items that the existing stateless provider-neutral transcript cannot preserve across a tool round-trip. Do not advertise `.reasoning` or effort controls. If an opaque reasoning item is returned despite this request, fail with a protocol error rather than silently discard state. Expose only capabilities the adapter handles: text, streaming, and tools.

## Tasks

### 1. Provider registry contract

- Add tests first for exact provider lookup, unknown-provider failure, and adapter-revision mismatch.
- Implement a small immutable Provider ID to existing `ModelProvider` registry. It has no factories, plugins, fallback, or runtime behavior.
- Keep existing one-provider initializer call sites source-compatible where possible by wrapping their adapter in a one-entry registry.

Expected: the registry returns the selected adapter only for an exact ID/revision and reports typed failure otherwise.

### 2. OpenAI request and response contract

- Add tests first for the default full endpoint, custom instance endpoint behavior, model descriptor/capabilities, bearer authentication, Responses request JSON, and tool schema/function output encoding.
- Implement the OpenAI `ModelProvider` with the existing `HTTPTransport`, frozen config seed, and credential binding.
- Do not log or persist key material; use the existing redacting request/transport and typed provider errors.

Expected: request construction matches the current Responses contract and all secret values stay out of observations and diagnostics.

### 3. OpenAI stream contract

- Add tests first for semantic text deltas, terminal completion, multiple indexed function calls with argument deltas, function-call completion, usage/finish mapping, protocol errors, transport errors, and cancellation.
- Implement SSE semantic event parsing on top of the existing byte parser and transport. Accumulate calls by output index and preserve each provider call ID; emit only complete calls. Require an accepted semantic terminal event before normal completion.
- Map errors using existing `ProviderError` semantics and delivered model output. Never retry in the adapter.

Expected: text and complete tool calls stream through `ProviderStreamEvent`; malformed/incomplete streams fail, and consumer cancellation cancels the underlying HTTP stream.

### 4. Runtime and setup routing

- Add tests first for OpenAI instance creation/selection, DeepSeek/OpenAI coexistence, request routing by frozen Run Provider ID/revision, recovery route preservation, no default fallback, and explicit Child provider binding.
- Add the registry to AppAssembly and route new Runs by the selected instance. Route every stream and rebuild/recovery path by the frozen execution snapshot. Keep existing tool policy, projection, and child ownership unchanged.
- Wire account setup, Settings catalog/default/configuration, and Subagent model options to the same registry. Add a Provider picker to account setup.

Expected: a Run never changes adapter due to a current default or mutable selection; explicit routing failures surface through existing Runtime recovery/dependency failure semantics.

### 5. Verification and delivery

- Run the relevant contract tests via CI because the Windows workstation has no Swift/Xcode toolchain. Do not claim local native build or XCTest success.
- Run local static checks available on Windows: XcodeGen/workflow cross-reference and YAML, path existence, ignored generated-project artifacts, LF line endings, and `git diff --check`.
- Review the final diff against the explicit path ownership list; commit and push only this branch; verify the pushed remote SHA; open a draft PR to `main` if the configured GitHub flow permits it.
- Record exact commit, CI run/result, static command results, and remaining limits in the task record.

## Review focus

- Registry resolution is used by every new Send, existing Run, cold-start recovery, authentication retry, and explicit Child path. No operation silently uses a default adapter.
- OpenAI streaming preserves multiple calls, ordering, function `call_id`, terminal semantics, cancellation, and partial-output recovery rules.
- Settings can create an OpenAI instance and choose a supported model through the same credential path; DeepSeek remains available.
- Run execution snapshots and seeds remain compatible with current persistence; ToolPolicy and approval remain in the existing Runtime.
