# Hermes iOS repository guide

This repository contains the SwiftPM source for the Hermes iOS client and its
build and verification scripts. Keep the WebUI, backend, reverse proxy, ports,
and server deployment outside this repository.

## Source of truth

- Start a new concentrated product repair batch from the current GitHub `main` HEAD. The project manager owns one product integration branch; module workers branch from that integration HEAD and open PRs targeting it. Only the manager creates the final release PR targeting `main`.
- Create one short-lived branch per change. Use `feat/`, `fix/`, `chore/`, or
  `docs/` prefixes.
- Use a separate Git worktree for each concurrent agent. Never share a mutable
  checkout between agents.
- Submit changes through a pull request. Do not push directly to `main`.
- Personal project: **ordinary and high-risk iOS product fixes both require no human review or approval**. A version-bumped product PR auto-merges only after the batch acceptance matrix is verified against the full open-Issue set, exact-HEAD release identity, all four Swift offline shards and the IPA check pass. High-risk changes additionally require targeted deterministic safety regression and code-level agent self-review. Simulator UI regression remains independent; a real-phone test is not a routine prerequisite. Use `hold` or `no-auto-release` only for a concrete unresolved correctness/security failure or an explicit user pause; risk classification or Draft alone is not a hold. CI/workflow/privileged scripts require a separate checked PR and an agent-initiated explicit merge (not a product auto-release); no human reviewer is required.
- Rebase or merge the latest `main` before requesting merge. Resolve conflicts
  on the feature branch.
- Do not wait for another GitHub identity, human review or manual approval for any iOS product fix, including Run/Session/POST/queue/STOP changes. Three exact-head CI checks are the routine gate; targeted deterministic regression and code self-review are mandatory for high-risk fixes.

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

- Release identity (version/Info.plist/Bundle ID only): `python tests/check_release_identity.py`
- Historical file-hash inventories and per-build Release Scope manifests are not release gates.
- Core tests: included in `bash tests/run_container.sh`
- Native tests: `bash tests/run_container.sh` for all suites locally, or `HERMES_TEST_SHARD=core|recovery|interface|media bash tests/run_container.sh` in four independent Ubuntu CI shards. Each suite has a time limit.
- Release automation: `python -m unittest discover -s tests/releaseautomation -p 'test_*.py' -v`
- iPhoneOS candidate: the same-repository PR workflow runs release identity checks,
  four independent offline test shards with one mandatory aggregate, and a single
  IPA build in parallel; it retains one immutable candidate Artifact. Main
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
  an automatic human approval hold. A high-risk label alone is never a reason to stop coding or request review. Block only when a concrete safety invariant is
  unverified, incorrect, or a required CI check fails.
- Each PR must link affected Issues: use `Fixes #N` when all acceptance requirements are implemented and tested; plain `#N` for partial work. Following a successful Release, the workflow comments on referenced Issues and closes only explicit fixes.
- Only mark a fix delivered after the exact IPA appears in a successful Release.
  Never claim a real-phone acceptance based only on XCTest or an IPA compilation.

## Autonomous full-Issue batch-to-Release loop

1. The single project manager reads the live `main` HEAD, **every** open Issue and PR, Release, Actions and simulator results. Build a complete acceptance matrix for the batch; delegate disjoint modules to workers and map aggregate audit Issues to their children. Do not select only one Issue per cycle.
2. The project manager owns **one** product integration branch. Workers create independent branches and PRs targeting that integration branch, not `main`; they may not bump versions, create product Release PRs, or publish IPA/Bark. Review worker changes, preserve safety invariants, and integrate compatible fixes into the same batch.
3. Each Issue must have a concrete conclusion with code and test evidence: fixed and verified, already fixed in an earlier Release with proof, test false positive with proof, or externally blocked with a specific contract/failure and safe client fallback. Partial fixes and unexamined Issues do not satisfy batch acceptance.
4. A batch can span multiple scheduled runs. **Never release a subset merely because its three CI jobs passed.** Continue the same integration branch until all executable fixes have been implemented and all remaining external blockers are documented.
5. Only the project manager updates the release identity and the machine-readable batch acceptance matrix, opens the one versioned product PR against `main`, and runs exact-head release identity, all offline Swift shards, IPA and applicable simulator checks. High-risk fixes additionally require focused safety regression and self-review; no human review is needed. A trusted release gate must reject absent, stale or incomplete batch acceptance evidence.
6. Following a verified Release and identical IPA promotion, reconcile each Issue against its full acceptance criteria; close only proven fixes. Aggregate audit Issues close only after all children are resolved. Do not split the remaining queue into default partial releases.
7. Changes to `AGENTS.md`, CI/workflow or privileged scripts require a separate maintenance PR based on `main`, tested and explicitly merged by the project manager; they are not product release changes.

## Pull requests

A pull request should explain the user-visible problem, the resulting
behavior, the scope, and the checks performed. Include before/after evidence
where it helps. Keep unrelated refactors out of functional fixes. Call out
known limitations and anything still requiring physical-device testing.

The fixing agent must self-review and verify before automatic merge:

- the change is limited to the iOS client where applicable;
- message IDs, scroll anchors, and streamed rendering remain stable;
- attachments and text selection do not regress;
- no secrets or generated artifacts are included;
- tests are meaningful and their claimed coverage matches what ran.
