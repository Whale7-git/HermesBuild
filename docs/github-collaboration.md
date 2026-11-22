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

## Issues, fast releases, and simulator discovery

- Start every user-requested feature/fix by searching GitHub Issues, creating or
  updating one when there is concrete scope, and linking its PR. Publishing the
  Release (not merely merging a PR) completes delivery.
- The trusted auto-merge gate requires only the successful exact-head candidate
  workflow and its three jobs; it still checks release identity, source scope,
  privileged paths, manual hold labels and immutable candidate provenance.
  Privileged CI/workflow/script changes use a checked PR and explicit merge;
  ordinary personal-app fixes have no additional human approval gate.
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
  need focused pre-release tests and code review, not automatic human holds.
  Use `hold` for a concrete unverified safety invariant or failed CI check.
- Following a successful Release, referenced GitHub Issues receive release evidence:
  `Fixes #N` is closed once delivered, plain `#N` remains open for follow-up.

The existing Release and Bark links remain the delivery source of truth.
