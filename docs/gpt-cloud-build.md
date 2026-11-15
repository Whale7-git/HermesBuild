# GPT Cloud Build v2 — authoritative branch contract

Scope: repository `Whale7-git/HermesBuild`, only `gpt/**` branch Push events. The only GPT workflow is `.github/workflows/gpt-cloud-build.yml`. No main writes, Release, tag, signing, Bark, 9th build host, SSH, remote Docker, or xtool. Cache design is outside this contract.

## Exact pipeline

1. `source` on Ubuntu 24.04 verifies source inventory, negative mutation cases, SwiftUI checks and GPT build-contract tests.
2. `offline` on Ubuntu 24.04 compiles and runs all locally runnable Swift suites; no live services.
3. Once BOTH succeed, `ipa` on GitHub-hosted macOS 26 runs XcodeGen and Xcode to compile a real unsigned Release iPhoneOS arm64 app from the actual sources.
4. `tests/verify_ipa.py` checks the app structure, required resources, binary architecture, lack of code signing, version and security invariants. `scripts/gpt-cloud-verify.py` independently checks exact SHA, embedded `HermesGitSHA`, version/build, checksum manifest and verification report.
5. GitHub stores the verified IPA, `build-info.json`, `validation.json`, `SHA256SUMS.txt` and GPT build report together as an Actions Artifact; logs and error summary are uploaded even on failure.

Each mode checks the exact push repository/ref/HEAD SHA in Actions. Local runs require a real `gpt/*` branch; IPA packaging additionally requires a clean committed working tree. Tool versions are recorded and checked for a compatible Xcode 26 and XcodeGen >= 2.42. Patch drift is visible, not silently described as a tested immutable toolchain.

## Entry points

- `bash scripts/gpt-cloud-build.sh source`
- `bash scripts/gpt-cloud-build.sh offline`
- `bash scripts/gpt-cloud-build.sh ipa` (macOS only)
- `python3 tests/gen_release_scope.py` (run once after file changes)
- `python3 -m unittest discover -s tests/gptcloud -p 'test_*.py' -v`

The source gate validates the current XcodeGen app target and GitHub builder. Former 9th-runner/xtool scripts and remote wrappers have been removed from this GPT branch; they are not a fallback or implicit dependency.

## New-version development

1. Create a short-lived `gpt/<topic>` branch based on the current GPT integration branch, which must already contain the GPT workflow. A plain `main` branch may not contain this workflow.
2. Change real app sources and add relevant tests. Keep Bundle ID, Keychain/instance identity, chat anchors, native sessions and attachments stable.
3. When changing app version/build, edit `release.json` (the source of truth), `Resources/Info.plist` and the first line of README together. A build-chain-only change does not imply a new app version.
4. Run the scope generator once; review the diff and tests before committing. Push the branch.
5. Confirm the same exact Git SHA appears in the source/offline/macOS jobs, embedded app plist, build metadata and IPA verification. Download and sign the candidate yourself for real-device checks.

A candidate is not a separately numbered official release merely because its SHA differs. It is not eligible for automatic promotion into `main`. This GPT branch contains no separate candidate-promotion or Release workflow; the original `main` workflows are outside this branch.

## Failure diagnosis

The macOS job uploads setup/build/toolchain logs, reports exact failed step outcomes, retains full Xcode build output, and writes an Actions job summary. Source/Swift test failures appear as their own Ubuntu jobs. Treat a missing IPA, failed provenance validation, or upload error as a failed build; do not report the artifact as delivered unless GitHub confirms upload success.

Historical material: `docs/backlog.md` and `tests/manual-ios.md` are not authoritative current build instructions. The former SSH wrappers and `ci/` scripts have been deleted from the GPT tree, without modifying `main`. See `docs/gpt-cloud-legacy-cleanup.md`.
