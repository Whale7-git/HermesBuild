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

## Legacy isolation and history

Only `.github/workflows/gpt-cloud-build.yml` remains as a workflow in this GPT branch. Historical 9th-runner, xtool, SSH wrappers and official publication/candidate automation were removed **from this GPT branch only**. Never reintroduce or call them in GPT development. `main` was not changed by the deletions.

Preserve real Swift offline suites, source integrity tests and IPA validation. Live backend probes remain optional manual checks, not CI dependencies. See `docs/gpt-cloud-legacy-cleanup.md` for the removed inventory and `docs/gpt-cloud-build.md` for the build contract.
