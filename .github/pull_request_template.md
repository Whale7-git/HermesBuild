## Problem

Describe the user-visible issue and how to reproduce it.

## Change

Describe the resulting behavior and the narrow scope of this pull request.

## Verification

- [ ] Source checks
- [ ] Relevant offline tests
- [ ] Release build or IPA inspection when applicable
- [ ] Physical-device checks are listed separately and marked as pending when not run

Commands and evidence:

- PR head SHA:
- PR tree SHA:
- Producer run ID and attempt:
- Candidate Artifact ID, name, and digest:
- Promotion run:
- Release URL:

Non-release maintenance PRs may mark the candidate, promotion, and Release
fields as N/A. Release PRs must fill them after the matching run completes.

## Risk and rollback

Call out layout, scrolling, streaming, attachment, selection, storage, or
compatibility risks. Explain how to roll back.

## Checklist

- [ ] No credentials, cookies, keys, or local build artifacts are included.
- [ ] Unrelated files and refactors are excluded.
- [ ] The change preserves bundle ID, paging, scroll-following, tool-call
  collapsing, expansion state, and session-list navigation.
- [ ] The description distinguishes offline tests, Release compilation, IPA
  inspection, and real-device acceptance.

## Automatic release policy

Versioned iOS PRs with only approved product/test files, and
the exact-head candidate workflow's three mandatory jobs fully green will automatically leave Draft, merge to
main, and explicitly start promotion of the already verified candidate IPA.
No extra compilation or interactive ChatGPT session is needed.

To keep a PR pending, add one of these labels:
`hold` or `no-auto-release` for concrete safety failures or an explicit pause. CI/automation edits, non-release
changes, and failed tests never auto-merge. Physical-device testing remains separate and is not a routine release gate.
Use `Fixes #N` for fully resolved issues, plain `#N` for partial fixes.
Post-Release Issue sync records release evidence and closes only explicit fixes.
