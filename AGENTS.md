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
- Rebase or merge the latest `main` before requesting review. Resolve conflicts
  on the feature branch.
- Shared GitHub identities cannot approve their own pull requests. In that
  setup, another agent reviews through PR comments and the required CI check
  must pass before the lead merges. Require an approving review only after the
  repository has at least two independent GitHub identities.

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
- Do not commit `.build/`, `.bsp/`, `xtool/`, `releases/`, IPA files, SDKs,
  caches, private keys, tokens, cookies, or local machine configuration.

## Validation

Run the smallest relevant checks while developing and the full applicable
suite before requesting review. State what was actually run and keep offline
tests, Release compilation, IPA inspection, and physical-device acceptance
separate.

- Source verification: `python tests/verify_source.py`
- Source-gate regression: `python tests/sourcegate/main.py`
- Core tests: included in `bash tests/run_container.sh`
- Native tests: `bash tests/run_container.sh` (uses the runner’s preinstalled Swift in CI; its version is logged); optional remote wrapper `tests/run_native.sh` requires local SSH configuration
- iPhoneOS build and IPA: new version/build pushes to public main automatically build and publish after checks;
  workflow_dispatch only builds/verifies. Use a locally configured Xcode / xtool environment for local work. Do not claim device behavior was verified without a
  real-device result.

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
