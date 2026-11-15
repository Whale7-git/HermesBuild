# GPT branch legacy build isolation audit

**Scope:** `gpt/cloud-build-bootstrap` and descendant `gpt/**` branches only. The `main` branch, official releases and existing remote hosts are unchanged.

## Removed from this GPT branch

- Three former GitHub workflows: `hermesshell-adaptive-release.yml`, `hermesshell-single-build.yml`, `hermesshell-single-promote.yml`. Only `gpt-cloud-build.yml` remains.
- Entire old self-hosted `ci/` tree (14 files), including its obsolete host-specific cache script. No GPT caching design or configuration was changed.
- Three legacy SSH/xtool build scripts: `scripts/build-on-9.ps1`, `scripts/release-local.sh`, `scripts/repro-check.sh`; also `xtool.yml`.
- Seven old publication/candidate scripts: `github-build-ipa-main.sh`, `github-publish-release.sh`, `publish-candidate.py`, `publish-release.py`, `release-plan.py`, `select-candidate.py`, `verify-candidate.py`.
- Six remote-only test launchers: `tests/run_native.sh`, `tests/core/run.sh`, `tests/attachments/run.sh`, `tests/attachments/typecheck-ios.sh`, `tests/discovery/run.sh`, `tests/discovery/typecheck.sh`.
- Five tests under `tests/releaseautomation/` that depended on removed publication workflows.

**Total removed: 39 files.** Removal of the old host-specific cache staging script only retires a component of the obsolete CI tree; no independent GPT cache workflows or plans were changed.

## Preserved

- Real application sources, resources, Textual vendor code, Package.swift, ios-ci-project.yml and the original Bundle ID.
- `tests/run_container.sh`, all 49 offline Swift suites, attachment fixtures, discovery/gateway/rendering tests, and source integrity/mutation tests.
- GPT-only source/offline/macOS entry point, XcodeGen-based IPA packager, toolchain and provenance validation, reports and Actions artifacts.
- Historical research and manual acceptance documents labeled as historical.

## Verification

The source job checks that deprecated files and extra workflows remain absent. The offline job runs all Swift suites; the hosted macOS job compiles and verifies the exact source SHA and uploads a validated unsigned IPA and diagnostics. Neither SSH, xtool, self-hosted runners, signing, Bark nor Release publication is needed.

Older implementation code remains accessible through `main` or Git history. Do not reintroduce it without an explicit request.
