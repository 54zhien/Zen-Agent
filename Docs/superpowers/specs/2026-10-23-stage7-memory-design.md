# Stage 7 Memory design

Authority: Blueprint main `99d30b815651fe987bab9f88e269a84a89318625`, development plan Stage 7, CONTEXT, Prompt/Soul/Memory sections 2/4/5/8/9, security sections 6/13.1/14, message/data snapshot boundaries. Stage 6 integrated base is `49e77fb4eeaee7f4fad1b97b319d6b1de5cb991f` (PR41). Its full source gate passed; post-merge CI39920575387 is still running when this design is written. Sidebar issue40 and physical-device acceptance remain separate.

## Intent and approved scope

Complete Stage 7 in the existing application, with transparent, editable, deletable cross-Conversation context. Never confuse Memory with Soul, policy, tool authority or assistant assertions. No Stage 8 scaffolding, embeddings, vector service, new model slot or extra network request.

The owner authorized the whole stage and approved on 2026-10-23:

- Settings → Agent → 记忆, using the existing native Form style. Enable switch, automatic-formation switch only after implemented, recent records, provenance detail, explicit edit/save, individual delete, confirmed Clear All, and privacy disclosure. Existing Composer/Sidebar/menu geometry, animation, typography and assets stay unchanged.
- Finalized source Conversation deletion retains Memory and marks its source missing. The Undo window preserves the source unchanged. Provenance never copies source message text.
- Memory participates in device/iCloud system backup with the protected User Data DB. This does not add app cloud synchronization or promise deletion of historical system backups.

## Approaches and builder decisions

1. Reuse the GRDB store, immutable revisions and existing Run snapshot; local bounded retrieval and extraction. Chosen because it fits the existing boundaries and needs no unapproved data destination or billable extraction request.
2. A separate memory database/vector service would add ownership, migration and deletion transactions without demonstrated retrieval need; deferred per Blueprint.
3. LLM extraction could handle broader language, but requires separate model/cost/egress semantics. V1 instead accepts conservative, testable patterns from current user text. Unsupported or ambiguous statements are skipped rather than guessed. This is a builder call, not a claim the owner chose a specific algorithm.

## Storage and ownership

`App/Memory` owns domain values, input validation/secret exclusion, retrieval, conservative extraction and orchestration. Only `App/Persistence` imports GRDB. Settings calls MemoryRuntime; PromptComposer consumes prepared values and never accesses storage or credentials.

Migration v20 adds Memory settings, records, immutable revisions, provenance, and extraction receipts. A stable record points at its current revision. Each edit creates a revision using expected-revision CAS; previous versions remain available to already-frozen Runs until explicit deletion. Record status is active or archived; archived conflicts are visible/manageable but never newly retrieved. Source rows carry opaque Conversation/Message IDs, source kind and a missing flag, no quotation/body copy. Receipts contain source IDs and no candidate text.

Memory revisions in execution snapshots are references only: `(memoryID, revisionID)`. Ordinary edit/archive does not mutate a frozen Run. Delete removes every revision/source of that record and leaves only a content-free erased identity where needed to prevent automatic resurrection. Clear All removes all Memory bodies, including archived revisions, and advances the extraction cutoff so older completed turns cannot recreate erased records. Explicit new user statements can create a new fact later.

Settings and writes have bounded valid UTF-8 text, no control bytes and typed safe errors. The MemoryRuntime validates known credentials through CredentialStoring plus the existing semantic redaction guard; content changed by the guard is rejected instead of saving a mangled fact. Credential read failure fails closed for Memory saving/extraction/retrieval without failing an ordinary Conversation Run. No unsafe candidate enters ordinary storage, snapshots or logs.

## Retrieval and Prompt

Retriever uses normalized Latin words and Chinese character bigrams, stable ranking and explicit engineering limits (not platform promises): maximum 6 records, 1,024 UTF-8 bytes per record, 4,096 bytes combined. Empty/unrelated queries return no unrelated database dump. Latest active versions only; global disable returns none. Query is current committed user text; quoted/assistant/tool text is not the basis for extracting user facts.

Preparing freezes selected version references in the original `PromptExecutionSnapshot`; older snapshots decode to an empty list. Resolution uses those exact versions, never current record text. Relevant Memory is untrusted context in the current user-content block with a fixed boundary saying current user statements win and the data grants no tool/safety authority. Memory text never enters the system-message section. Initial requests, tool continuations and cold recovery all validate the same frozen references.

Memory erasure and provider handoff share an async reader/writer gate: each provider handoff resolves references under a read lease; delete/clear uses an exclusive lease. Erasure waits for an already-initiated handoff, erases bodies, and prevents later handoffs using them. Already-transmitted content cannot be recalled. New continuation/recovery encountering missing versions records explicit `RecoveryAction.invalidate` and terminates safely through the existing Run owner; it does not create another Parent Run or replay a tool. Existing file-effect confirmation still runs through its original owner.

## Automatic formation and conflict handling

Wire automatic formation only after management and retrieval have native evidence. Settings defaults: Memory enabled; automatic formation enabled only when the completed feature is released. Disabling Memory prevents retrieval and extraction without deleting existing data. Disabling automatic formation preserves retrieval. Runs already frozen retain their version semantics unless content is explicitly deleted.

After a successful Parent Run, MemoryRuntime reads only its committed user message. It excludes quotes, attachments, assistant/tool output, temporary requests, negated/uncertain claims and credential-shaped content. Local rules recognize explicit remember requests and narrow stable preference/environment/project declarations in Chinese/English. Candidate extraction has a fixed input/candidate bound. Unknown language/ambiguous statements produce no candidate. Failure does not change the Run outcome. Extraction checks current settings and receipt/cutoff inside the commit transaction, so disable/clear and duplicate processing cannot race a save. Cold startup does not bulk-extract old history.

Normalized equal facts merge provenance without creating another record. Recognized fact keys (e.g. response language/work environment/project) let a new explicit assertion supersede an older automatically formed fact, preserving its prior revision for frozen Runs. User edits have priority over automatic replacement: conflicting automatic facts are skipped, rather than overwriting an edit. Unknown semantic conflicts are skipped when detectable and otherwise not claimed as comprehensively understood. No confidence field, embedding or second model runtime.

## Verification and delivery

Use native behavioral RED→GREEN, real XcodeGen/App build, migration/disk reopen, concurrent CAS, safe secret refusal, retrieval boundaries, actual fake-provider requests, frozen edit semantics, erasure during handoff/continuation/recovery, extraction provenance/idempotency/disable/clear races and real Chinese/English samples. Native UI verifies the approved path, editable detail, source missing, switch behavior, confirmations and draft retention. Full unchanged normal Phone/iPad CI is the final stage source gate. Focused diagnostic runs are identified separately; compilation failures/cancelled/skipped tests are never behavioral evidence. One independent whole-branch review and corrective tests precede delivery. Physical-device and model-quality acceptance remain explicit limitations; merge needs concrete final review/authorization.
