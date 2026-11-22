# HermesBuild agent instructions

This is a personal iOS repository. Read the live `main` HEAD, `release.json`, code and GitHub Issues rather than trusting historical build notes.

## Ownership and collaboration

- For a concentrated repair project, the manager reviews **every** open Issue and relevant PR, owns one integration branch and delegates independent modules. Workers send PRs to the integration branch; only the manager prepares a versioned product PR to `main`.
- Create short-lived `fix/`, `feat/` or `chore/` branches; do not push directly to `main`. No human reviewer or approval is required for ordinary or high-risk fixes.
- Use the current GitHub Issues as the backlog; do not present old Markdown plans as current work. Record regressions and unresolved external gateway contracts accurately.
- Keep CI/workflow, privileged scripts, and GitHub-token changes on an **independent maintenance PR** with an explicit agent merge. This isolates token permissions from automatically merged product PRs; it is not a test/quality gate.

## Development constraints

- Bundle ID stays `com.whale7.hermes`; preserve per-instance/account Keychain boundaries.
- Never ship credentials, private logs, auth headers, real messages, signing keys, SDKs, IPA binaries or generated build directories in Git.
- Preserve at-most-once original POST, accepted Run/Session identity, user-owned queue pause, safe STOP semantics, message scroll anchors, attachment isolation and non-replay on uncertainty.
- On high-risk changes, write focused deterministic regressions and independently review side effects. Report results honestly; a successful compile is not proof of runtime correctness.

## Nonblocking diagnostics

- `bash tests/run_container.sh` runs the complete local Swift suite. In GitHub, `.github/workflows/hermes-offline-diagnostics.yml` runs four isolated `HERMES_TEST_SHARD` values: `core`, `recovery`, `interface`, `media`.
- Python navigation, SwiftUI and release-automation tests run in the same separate diagnostics workflow. All tests retain PASS/FAIL and per-suite timing; they are **nonblocking** to the app's merge and Release. Failures must still be investigated.
- There is **no historical source-file hash gate, Release Scope regeneration requirement, global Issue matrix gate, mandatory green offline test requirement, or manual approval/hold-label gate**.
- The only basic release-identity check is `python3 tests/check_release_identity.py`, checking version, Info.plist, README header and Bundle ID. It is advisory in the diagnostics workflow; the candidate build independently requires a structurally usable version and IPA.

## Candidate and Release

- `.github/workflows/hermesshell-single-build.yml` compiles **one** unsigned iOS candidate on macOS, checks the actual IPA, and uploads an immutable candidate Artifact; source/Swift diagnostics never delay it.
- `.github/workflows/verified-release-automerge.yml` uses trusted `main` code to merge a valid version-increasing product PR once its candidate compilation succeeds. It does **not** require an Issue acceptance file, test success, simulator outcome or a reviewer.
- `.github/workflows/hermesshell-single-promote.yml` publishes the exact candidate bytes with tree/SHA/digest verification; it does not recompile. A mismatch, missing file, failed compilation, or duplicate release identity cannot be published, because there would be no trustworthy IPA.
- Simulator UI checks are **manual-only** (`Actions → Hermes iOS Simulator UI regression → Run workflow`, select `gold`, `audit` or `all`). No PR, schedule or post-Release trigger, no simulated UI commit-status gate. Launch only when a concrete UI symptom requires XCTest evidence; do not require simulator passes for Release. Bark success/failure notification is best effort and distinct from actual Release status.
- For a concentrated repair project, an agent should still aim to finish all executable fixes in one Release. But an unfinished Issue or diagnostic FAIL must be **visible and tracked, not a hidden build gate**. Close Issues only when fixes are truly delivered, not merely because publication succeeded.

## Documentation

`README.md` and `docs/github-collaboration.md` describe the current process. Git history retains historical planning documents; obsolete version-specific Markdown is intentionally not part of the active working tree. Preserve third-party notices and actual Gateway protocol contracts.
