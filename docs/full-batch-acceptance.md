# Full-Issue batch acceptance matrix

The project manager creates `tests/release-batch-acceptance.json` **only on the final product PR**. This file is intentionally not committed by the maintenance PR. The trusted auto-merge gate reads it from the exact PR HEAD and rejects a versioned release PR unless every live open Issue is represented.

Schema (illustrative placeholders, not an accepted batch):

```json
{
  "schema": 1,
  "base_sha": "FULL_CURRENT_MAIN_SHA",
  "version": "NEXT_VERSION",
  "build": 227,
  "issues": [
    {
      "number": 85,
      "disposition": "fixed",
      "evidence": "https://github.com/Whale7-git/HermesBuild/pull/NUMBER",
      "acceptance": "Describe the exact tested acceptance and run URL, not a generic CI green."
    }
  ]
}
```

Every currently open Issue (excluding pull requests) must appear once. Valid dispositions: `fixed`, `already_released`, `test_false_positive`, `external_blocked`. Each requires a GitHub evidence URL and a substantive acceptance explanation; an external blocker additionally requires a `blocker_contract` of at least 24 characters describing the actual endpoint/contract failure. No blanket "deferred" or "not checked" status is allowed.

This is a **structural machine gate**, not proof that the linked tests actually passed. The project manager must review each cited commit, job log and simulator result, and must not label an unverified or partly implemented Issue as fixed. The manifest `base_sha` must equal the PR's exact current main base; after main moves, rebase and regenerate. A changed manifest is required in the release PR, so stale prior release evidence is not silently reused.

The privileged gate lives in `.github/workflows/verified-release-automerge.yml`, executes only trusted main workflow code, and does not check out PR scripts. Its existing exact-head three-job CI, allowed-file checks and immutable IPA promotion remain mandatory.
