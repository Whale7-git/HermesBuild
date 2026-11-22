# Hermes iOS repository guide

This repository contains the SwiftPM source for the Hermes iOS client and its
build and verification scripts. Keep the WebUI, backend, reverse proxy, ports,
and server deployment outside this repository.

## Source of truth

- Work from the GitHub `main` branch.
- Create one short-lived branch per change. Use `feat/`, `fix/`, `chore/`, or
  `docs/` prefixes.
- Use a separate Git worktree for each concurrent agent. Never share a mutable
  checkout between agents.
- Submit changes through a pull request. Do not push directly to `main`.
- Personal project: version-bumped product PRs auto-merge on exact-HEAD source/scope, Swift offline and IPA checks, without human approval or a real-phone test prerequisite. Simulator UI regression remains independent. Use `hold` or `no-auto-release` only for a concrete unresolved correctness/security failure or explicit user pause; Draft alone is not a hold. CI/workflow/privileged scripts still require a checked PR and explicit merge, and must not trigger an app Release.
- Rebase or merge the latest `main` before requesting review. Resolve conflicts
  on the feature branch.
- Do not wait for a second GitHub identity or formal approval for normal app changes. Three exact-head CI checks are the routine gate.

## Scope and invariants

- Keep bundle ID `com.whale7.hermes`; SideStore updates rely on it.
- Preserve historical paging through `NativeChatModel.loadOlder()`, streamed
  reply following, collapsed tool calls, persistent expansion state, the
  "back to latest" affordance, and the right-swipe session-list gesture.
- Keep credentials out of source, logs, fixtures, documentation, and build
  output. Gateway credentials are per-instance API keys in the iOS Keychain.
  Never hardcode tokens or forward Bearer-protected uploads to other origins.
- Treat files under `Vendor/` as third-party code. Prefer a narrow, documented
  patch over broad rewrites.
- Do not commit `.build/`, `.bsp/`, `releases/`, IPA files, SDKs,
  caches, private keys, tokens, cookies, or local machine configuration.

## Validation

Run the smallest relevant checks while developing and the full applicable
suite before requesting review. State what was actually run and keep offline
tests, Release compilation, IPA inspection, and physical-device acceptance
separate.

- Source verification: `python tests/verify_source.py`
- Source-gate regression: `python tests/sourcegate/main.py`
- Core tests: included in `bash tests/run_container.sh`
- Native tests: `bash tests/run_container.sh` (uses the runner’s preinstalled Swift in CI; its version is logged)
- Release automation: `python -m unittest discover -s tests/releaseautomation -p 'test_*.py' -v`
- iPhoneOS candidate: the same-repository PR workflow runs all three jobs in
  parallel, compiles once, and retains an immutable candidate Artifact. Main
  promotion requires the successful PR run and verifies that exact Artifact
  without compiling again or rerunning PR checks. `workflow_dispatch` on the candidate workflow
  builds and retains a candidate but never publishes.
- Candidate diagnostics are a separate 7-day Artifact containing the captured
  toolchain, redacted build logs, and `build-report.json`. They do not alter the
  candidate file contract or Release assets. A diagnostic upload failure must
  not hide a verified candidate.
- The trusted `verified-release-automerge.yml` gate checks eligible release PRs and explicitly dispatches promotion after merge because GitHub-token merges do not start ordinary push workflows. Never skip the exact-head CI, artifact, or release identity checks.
- Build, validate, and publish only through the candidate/promotion workflows and the existing
  test entry points listed above. Historical manifests and backlog records are
  audit evidence, not runnable instructions. Do not claim device behavior was
  verified without a real-device result.

## GitHub Issues and background simulator findings

- Record user-requested features and confirmed defects as Issues; search existing open
  and closed Issues first, then reference the Issue from the PR.
- Test-only findings are **suspected**, not confirmed App defects. On simulator
  failures, the trusted default-branch triage workflow creates or updates
  deduplicated Issues with test names, SHA and CI evidence. Runner failures
  are classified separately.
- Ordinary UI test failures after publication do not retract or block a Release.
  Changes involving POST replay, user/session isolation, data durability, STOP or queue
  safety require focused deterministic regression and code-level self-review, but not
  an automatic human approval hold. Block only when a concrete safety invariant is
  unverified, incorrect, or a required CI check fails.
- Each PR must link affected Issues: use `Fixes #N` when all acceptance requirements are implemented and tested; plain `#N` for partial work. Following a successful Release, the workflow comments on referenced Issues and closes only explicit fixes.
- Only mark a fix delivered after the exact IPA appears in a successful Release.
  Never claim a real-phone acceptance based only on XCTest or an IPA compilation.

## Pull requests

A pull request should explain the user-visible problem, the resulting
behavior, the scope, and the checks performed. Include before/after evidence
where it helps. Keep unrelated refactors out of functional fixes. Call out
known limitations and anything still requiring physical-device testing.

Reviewers should verify:

- the change is limited to the iOS client where applicable;
- message IDs, scroll anchors, and streamed rendering remain stable;
- attachments and text selection do not regress;
- no secrets or generated artifacts are included;
- tests are meaningful and their claimed coverage matches what ran.
