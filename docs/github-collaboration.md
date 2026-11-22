# GitHub collaboration

Work from the latest `main` on a short-lived feature branch and submit a
same-repository pull request. Preserve the iOS client scope, existing instance
identities, Keychain isolation, and chat behavior. Do not commit generated
outputs or local machine configuration.

The release path has two workflows:

- `.github/workflows/hermesshell-single-build.yml` runs source checks, the
  full Swift offline suite, and the single `macos-26` candidate build in
  parallel. The build validates the IPA and uploads it for 14 days. An upload
  from an unsuccessful run is not eligible for promotion.
- `.github/workflows/hermesshell-single-promote.yml` runs after a
  merge to `main`, checks whether the version changed, and selects the exact
  candidate from the successful PR run. It verifies the candidate and publishes
  the same bytes without compiling again or rerunning the PR checks.

The mandatory candidate workflow (source/scope, Swift offline, and IPA compilation) must pass on the exact head and tree that will be merged. Simulator UI checks are independent and non-blocking for ordinary product releases. The
resulting `main` tree must match the candidate manifest. The candidate Artifact
contains the IPA, `build-info.json`, `validation.json`,
`candidate-manifest.json`, and `SHA256SUMS.txt`. A Release publishes the first
four files; `SHA256SUMS.txt` remains inside the candidate Artifact for its own
verification.

A separate `hermes-candidate-diagnostics-<run>-<attempt>` Artifact is uploaded
on success and failure, with a 7-day retention. Its explicit whitelist contains
the captured toolchain, redacted setup and build logs, `build-report.json`, and
candidate identity files when present. It is never promoted. Diagnostic upload is
best-effort so a temporary logging failure cannot invalidate a verified
candidate.

`workflow_dispatch` on the candidate workflow builds and retains a candidate
Artifact, but never publishes. Only a version-bearing merge to `main` can start
promotion. A maintenance merge checks the version and plans no release.

Published tags and assets are immutable. A missing, expired, mismatched, or
invalid candidate consumes the merged build; increment the build and repeat the
PR flow instead of substituting a local package. `BARK_URL` is an optional
repository Secret used by a separate best-effort notification job. Package
validation and device acceptance remain separate from source tests.

Do not print machine identities, proxy URLs, tokens, cookies, passwords, or
notification keys in public logs. Update the current release scope only after
reviewing the complete source change; preserve frozen baseline manifests,
historical release-scope manifests, and third-party notices.

The only current build and publication workflows are
`hermesshell-single-build.yml` and `hermesshell-single-promote.yml`. Historical
manifests may mention removed external build and publication entry points as
evidence; they are not instructions and must not be reintroduced.

## Hourly autonomous Issue loop

The scheduled GPT agent reads the latest Issues, PRs, Release and `main`, claims one actionable Issue, verifies any existing fix or implements and tests a missing fix, and creates/continues its linked PR. **Both ordinary and high-risk product fixes ship automatically after the exact-head three CI jobs pass; high-risk fixes also require targeted safety regression and agent self-review, never human review.** After promotion, verify the actual Release IPA, update Issue evidence and close only fully delivered fixes; then pick the next Issue on a later cycle. A read-only status report is not a substitute for a requested fix. Safety failures keep the PR/Issue open for continued automated repair, not an unreviewed release.

## Issues, fast releases, and simulator discovery

- Start every user-requested feature/fix by searching GitHub Issues, creating or
  updating one when there is concrete scope, and linking its PR. Publishing the
  Release (not merely merging a PR) completes delivery.
- The trusted auto-merge gate requires only the successful exact-head candidate
  workflow and its three jobs; it still checks release identity, source scope,
  privileged paths, manual hold labels and immutable candidate provenance.
  Privileged CI/workflow/script changes use a separate checked PR and an agent-initiated explicit merge, not an app Release; **no human approval is required**. Both ordinary and high-risk iOS product fixes use the same no-human-review automatic merge and promotion path, with extra targeted safety regressions and agent self-review for high-risk fixes.
- On promotion success, the workflow explicitly dispatches the main-branch
  simulator suite. The simulator also runs on relevant PRs and on its schedule.
  No simulator result can automatically invalidate a published immutable asset.
- The trusted `.github/workflows/simulator-issue-triage.yml` watches completed
  failed simulator runs, reads only small JSON test evidence, deduplicates
  fingerprints and upserts GitHub Issues. Distinguish XCTest assertion failures
  from infrastructure failures; a red run alone is not a confirmed App bug.
- Simulator Issue evidence includes failed test identity, exact source commit
  and Actions URL, with bounded and redacted assertion summaries. Re-run
  evidence may update existing Issues, but no Issue auto-closes on a single
  passing run; require fix PR and release evidence.
- Changes affecting POST replay, session/account separation, persistent state or STOP
  need focused deterministic pre-release tests and agent code self-review, **not human review or approval**.
  Use `hold` only for a concrete unverified safety invariant, failed CI check or an explicit user pause; the risk label itself is not a hold.
- Following a successful Release, referenced GitHub Issues receive release evidence:
  `Fixes #N` is closed once delivered, plain `#N` remains open for follow-up.

The existing Release and Bark links remain the delivery source of truth.
