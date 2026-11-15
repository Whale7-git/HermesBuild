## Problem

Describe the user-visible issue and how to reproduce it.

## Change

Describe the resulting behavior and the narrow scope of this pull request.

## Verification

- [ ] Source checks
- [ ] Relevant offline tests
- [ ] GPT hosted macOS IPA build and artifact validation when applicable
- [ ] Physical-device checks are listed separately and marked as pending when not run

Commands and evidence:

## Risk and rollback

Call out layout, scrolling, streaming, attachment, selection, storage, or
compatibility risks. Explain how to roll back.

## Checklist

- [ ] No credentials, cookies, keys, or local build artifacts are included.
- [ ] Unrelated files and refactors are excluded.
- [ ] The change preserves bundle ID, paging, scroll-following, tool-call
  collapsing, expansion state, and session-list navigation.
- [ ] The description distinguishes source/offline tests, unsigned IPA
  compilation, artifact inspection and separately reported real-device acceptance.
