# S6-04a Runtime Policy integration

Owner continued after S6-03 merge and the disclosed S6-04 Tool approval impact. Plan: [2026-10-22-s6-04a-runtime-policy.md](../Docs/superpowers/plans/2026-10-22-s6-04a-runtime-policy.md). Blueprint fffca086, approved Stage6 roadmap/S6-04. Start with a complete backend vertical slice; no accepted UI View/layout/animation changes. System consent and grant-scope choice are S6-04b, not silently claimed complete.

Base main1fd98c6572553d257120d99b1f7eabb9c859448a/tree5c5d681bbbfd3000f11c1f29f2a6ad01a52882e2; identical candidate passed full39761453960. Post-merge main39769209066 still running at setup. UI PR37 remains parked/draft/unmerged and its source checkout is not taken over.

RED/GREEN, review and final complete native gate pending. Tests use actual original-call state/results/executor observations. Windows parsing/static checks cannot substitute for an Apple SDK build. No S6-04/Stage6 aggregate or device acceptance claim.

Actual native RED:1bf5bab97fa25ff2243936869c204bad57b34d47/run39771501697/job119799965480,17tests/1suite/31issues in2.236s. XcodeGen/app/native test build passed. Exactly1actual Swift run, no Phone UI; Pad intentionally skipped in focused RED profile. Positive explicitAlwaysAllow/dispatched-before-executor and duplicate-dispatch controls passed. Raw log SHA256092adc0e3919f7971168c5d2bbe05829762d3127c34d78d11eebab11d7ec1ab1. Four extra controls were added locally before implementation, outside immutable17-function RED; no separate observed RED claimed for them. Final workflow already restored.

Implementation candidate: v15 original-call admission + typed failure reason; reuse S6-01 evaluator in creation/approval/transactional dispatch, issue S6-03 once grant atomically with approval, exact displayed-intent witness, and live/cold recovery reapproval on the same call. Existing automatic virtual-ledger fixtures explicitly opt into low-risk alwaysAllow; required/high-risk fixtures retain manual approval. No accepted View/layout/animation source changed. Migration and real continuation controls added; local static checks pass, SDK/full native gate and fresh review still pending.
