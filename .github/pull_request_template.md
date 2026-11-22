## Scope

Describe the observable change, affected areas and related Issues.

## Evidence

- Commit / tree SHA:
- Relevant tests: PASS / FAIL / NOT RUN
- Simulator or device evidence, if relevant:
- Candidate IPA Artifact and Release, if this is a versioned product PR:

Do not describe unrun checks as passed. Test and simulator results are diagnostic evidence, not automatic release gates.

## Safety

- [ ] No credentials, private user content, signing keys or generated IPA committed
- [ ] No uncertain original POST replay or cross-instance/session/run mutation
- [ ] Privileged workflow, token or governance changes are isolated in a maintenance PR

## Rules

Follow the repository-root [`AGENTS.md`](../AGENTS.md), the single authoritative source for development, CI, branch ownership and Release behavior. Use `Fixes #N` only when the Issue is fully solved; otherwise reference it without closing it.
