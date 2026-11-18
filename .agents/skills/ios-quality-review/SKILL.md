---
name: ios-quality-review
description: Coordinate evidence-led iOS UI consistency, interaction, state reliability, performance and regression audits of HermesBuild without silently changing app code or release workflows.
---

# Hermes iOS quality review (orchestrator)

Use for "audit the app", "improve consistency", "review UX", "find regressions", or a pre-release quality assessment. Read the live `AGENTS.md` first; its safety, source-of-truth, scope and release rules override this skill. This is **not** a new build or release system.

## Required inputs and baseline

1. Resolve `Whale7-git/HermesBuild/main` to an exact commit SHA; read `release.json` at that SHA. Never assume a version from old documentation.
2. Read the relevant source and test files at that pinned commit; inspect the existing `.github/workflows/hermesshell-single-build.yml` and `tests/run_container.sh` before recommending any gate.
3. Confirm the requested mode: **audit** (default, read-only) versus **fix** (authorized code changes in a new short-lived branch and PR).
4. State what is available: source, CI logs, screenshots, reproducible device steps and performance samples. Missing evidence is "not verified", not "pass".

## Sequence

- Run `ios-design-audit` to map existing tokens/components and detect *inconsistencies*, not intentional exceptions.
- Run `ios-interaction-audit` across chat, sidebar/browser, input, task center, attachments and long conversation.
- Run `ios-state-reliability` on a suspected correctness issue; inspect every awaited return and old-session callback.
- Run `ios-performance-diagnostics` only with comparable measurements; it may recommend where to collect samples when none exist.
- Run `ios-regression-guard` to map every proposed fix to the smallest existing test suite and device-only acceptance item.

## Required output

Deliver one prioritized issue register, with columns: ID, area, exact symbol/file, evidence, expected versus observed, impact (P0/P1/P2), confidence (confirmed/probable/hypothesis), test coverage, proposed minimal fix, and verification status (passed/failed/not run/device pending). Distinguish "code inspection suggests risk" from an observed user-facing defect. Link commit/PR and relevant tests.

P0 = possible message loss, duplicate send, cross-session writes, data exposure or irreversible state failure. P1 = frequently broken interaction or proven major performance regression. P2 = isolated polish/inconsistency without a correctness impact. Do not infer P0 from visual style alone.

## Change constraints

- Never push to `main`; use a change-specific branch and PR.
- A review does **not** authorize wide refactors, dependency additions, new CI workflows, version increments, IPA builds or automatic merge.
- Preserve Bundle ID, Keychain identities, session paging, scroll ownership, stopped/uncertain send semantics and public release process.
- Avoid importing real chat text, access tokens, private logs or credentials into issues/fixtures.
- Reuse the existing `tests/check_navigation_contract.py`, `tests/check_swiftui_modifiers.py`, offline suites and built-in diagnostic recorder rather than creating duplicate checks.
- CI success cannot prove gesture feel, actual frame rate or physical-device behavior; report those separately.
