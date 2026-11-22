---
name: ios-quality-review
description: Review and fix HermesBuild UI, reliability and experience bugs. For explicit repair requests or hourly Issue automation, prefer fix mode and deliver a tested PR instead of a read-only report.
---

# Hermes iOS quality review (orchestrator)

Use for "audit the app", "improve consistency", "review UX", "find regressions", or a pre-release quality assessment. Read the live `AGENTS.md` first; its safety, source-of-truth, scope and release rules override this skill. This is **not** a new build or release system.

## Required inputs and baseline

1. Resolve `Whale7-git/HermesBuild/main` to an exact commit SHA; read `release.json` at that SHA. Never assume a version from old documentation.
2. Read the relevant source and test files at that pinned commit; inspect the existing `.github/workflows/hermesshell-single-build.yml` and `tests/run_container.sh` before recommending any gate.
3. Use **fix** mode when a user requests repair or the hourly Issue automation selects a bug. Reserve **audit** for an explicitly requested read-only report. Do not ask the user to reconfirm explicit fix intent.
4. State what is available: source, CI logs, screenshots, reproducible device steps and performance samples. Missing evidence is "not verified", not "pass".

## Sequence

- Run `ios-design-audit` to map existing tokens/components and detect *inconsistencies*, not intentional exceptions.
- Run `ios-interaction-audit` across chat, sidebar/browser, input, task center, attachments and long conversation.
- Run `ios-state-reliability` on a suspected correctness issue; inspect every awaited return and old-session callback.
- Run `ios-performance-diagnostics` only with comparable measurements; it may recommend where to collect samples when none exist.
- Run `ios-regression-guard` to map every proposed fix to the smallest existing test suite and device-only acceptance item.

## Required output

In audit mode, deliver a prioritized evidence-backed issue register. In fix mode, select one actionable Issue, implement a minimal tested change, open or continue the PR, monitor exact-head CI, Release and Issue status; do not substitute another register-only report for executable work.

P0 = possible message loss, duplicate send, cross-session writes, data exposure or irreversible state failure. P1 = frequently broken interaction or proven major performance regression. P2 = isolated polish/inconsistency without a correctness impact. Do not infer P0 from visual style alone.

## Risk and autonomous delivery policy

The hourly agent follows **read Issues/PR/Release → choose one actionable Issue → verify an existing fix or implement a missing fix → linked PR → exact-head three CI jobs → auto-merge and publish → confirm Release and update/close Issue → continue next cycle**. Do not deliver only inspection notes when work is requested.

Ordinary and high-risk iOS fixes use the **same no-human-review automatic delivery path**. High risk (Run/Session identity, uncertain POST, stop semantics, queue ownership or persistent state) requires additional deterministic safety regressions and code-level self-review **before** the green CI and trusted auto-merge; it does **not** require manual approval, a reviewer, or a blanket hold. If a concrete safety invariant remains unverified/failed, or CI fails, keep the PR and Issue open, document the evidence and continue fixing instead of forcing release. Verify exact Release IPA delivery before closing a fully fixed Issue.

Privileged CI/workflow maintenance changes belong in a separate checked PR and agent-initiated explicit merge; no iOS product Release for maintenance-only work. Never silently widen the product autogate to privileged paths.

## Change constraints

- Never push to `main`; use a change-specific branch and PR.
- A read-only audit does not authorize a release. An explicit fix request or the scheduled Issue agent authorizes a narrow code fix, version increment and existing three-job CI/auto-release path. No new build workflow. Only block real safety violations or failing checks.
- Preserve Bundle ID, Keychain identities, session paging, scroll ownership, stopped/uncertain send semantics and public release process.
- Avoid importing real chat text, access tokens, private logs or credentials into issues/fixtures.
- Reuse the existing `tests/check_navigation_contract.py`, `tests/check_swiftui_modifiers.py`, offline suites and built-in diagnostic recorder rather than creating duplicate checks.
- CI success cannot prove gesture feel, actual frame rate or physical-device behavior; report those separately.
