## Scope and observable behavior

Describe the change, affected files, associated Issues and user-facing result.

## Checks performed (informational, never release gates)

- [ ] Relevant Swift/Python unit tests run; list PASS/FAIL/NOT RUN
- [ ] Simulator or device checked when relevant; list evidence explicitly
- [ ] Release candidate IPA compiled if version-bumped; link the actual Artifact

Test failures do **not** automatically block an IPA Release. Record failures and create/follow up with Issues; never claim unverified work passed.

## Candidate evidence (product Release PR only)

- Commit / tree SHA:
- Candidate workflow Run:
- IPA candidate Artifact:
- Released tag and IPA URL:

For maintenance PRs, mark IPA and Release as N/A.

## Security and data integrity

- [ ] No credentials, private user content, signing keys, or generated IPA in Git
- [ ] No cross-session writes or automatic replay of uncertain original POST
- [ ] Privileged workflow/tool edits are in a separate maintenance PR

## Current automation

`hermesshell-single-build.yml` only compiles and validates one candidate IPA. `hermes-offline-diagnostics.yml` independently runs four Swift shards and static checks, with failures visible but **nonblocking**. Versioned product PRs may merge and publish once the actual candidate is compiled; `hermesshell-single-promote.yml` reuses exactly the same tree and file bytes. No source hash inventory, Issue matrix, three-green-job rule, hold-label requirement or human review is applied.

Use `Fixes #N` only for fully delivered fixes; plain `#N` for partial work.
