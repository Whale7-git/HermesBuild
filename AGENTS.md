# Hermes iOS — GPT branch development guide

This guide applies to `gpt/**` development and its independent GitHub cloud IPA pipeline. Do not infer current build commands from old self-hosted/SSH/xtool comments or historical audit notes.

## Repository, branches, and releases

- Repo: `Whale7-git/HermesBuild`. Work only on `gpt/*` branches for GPT-led development.
- Start a short-lived `gpt/<topic>` from a GPT branch already containing `.github/workflows/gpt-cloud-build.yml` (currently `gpt/cloud-build-bootstrap`). Do not create it from bare `main` and assume GPT CI will exist.
- Never push to, merge into, change workflows on, or publish a tag/Release from `main` without an explicit separate request.
- The `gpt/**` Push workflow produces a verified **unsigned IPA Actions Artifact**, not an official GitHub Release. No Bark, signing credentials, private servers, SSH, or 9th-runner tools are required.
- Use separate worktrees/branches for independent agents. Integrate once and validate the final exact SHA, rather than combining successes from different commits.

## App invariants

- Preserve bundle ID `com.whale7.hermes` and iOS deployment target 18.0 unless expressly instructed otherwise.
- Preserve original instance IDs, per-instance Keychain credentials, native session history/recovery, draft storage, scroll anchors, tool-call attribution, streamed rendering, card geometry, and attachments.
- Never commit secrets, session identifiers, tokens, cookies, private URLs, generated IPAs, SDKs, or build output.
- Vendor code is third-party; apply narrow, audited patches with license notices.

## Current validation / packaging contract

- Source: `bash scripts/gpt-cloud-build.sh source`. This verifies the exact source inventory, gate mutation regression, SwiftUI checks, and GPT build-contract tests.
- Offline Swift: `bash scripts/gpt-cloud-build.sh offline`. Runs the full local Swift suite without SSH or live backend access.
- IPA: `bash scripts/gpt-cloud-build.sh ipa` on macOS with Xcode/XcodeGen; GitHub Actions runs it after the two Ubuntu jobs succeed.
- Final verification must match the same Git SHA, application version/build, embedded HermesGitSHA, unsigned arm64 binary, checksum manifest, validation report, and Actions artifact.
- Update `release.json`, `Resources/Info.plist` and README title together when changing a version. Run `python3 tests/gen_release_scope.py` **once** after any file changes. Never rewrite the frozen build64 baseline.
- Report test, compile, IPA verification and device acceptance as separate claims. Do not assert real-device behavior from green CI.

## Legacy entry points

`scripts/build-on-9.ps1`, `scripts/release-local.sh`, `ci/`, `xtool.yml` and `tests/run_native.sh` (plus SSH-based helper scripts under tests) are archived/manual legacy utilities. They are not GPT build dependencies, are not called by the GPT workflow, and must not become required by the source gate. Keep them available for history unless separately authorized to remove them.

`hermesshell-single-build.yml`, `hermesshell-single-promote.yml` and `hermesshell-adaptive-release.yml` are separate official/manual release workflows. They are not part of the GPT branch Push path.

The authoritative build architecture for this branch is `docs/gpt-cloud-build.md`.
