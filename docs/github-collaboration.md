# GitHub collaboration

Work from the latest `main` on a short-lived feature branch and submit a
same-repository pull request. Preserve the iOS client scope, existing instance
identities, Keychain isolation, and chat behavior. Do not commit generated
outputs or local machine configuration.

The release path has two workflows:

- `.github/workflows/hermesshell-single-build.yml` runs source checks and the
  full Swift offline suite, compiles one candidate on `macos-26`, validates the
  IPA, and uploads the candidate Artifact for 14 days.
- `.github/workflows/hermesshell-single-promote.yml` runs after a
  version-bearing merge to `main`, reruns source and offline checks, selects the
  exact merged-PR candidate, verifies its tree, manifest, Artifact digest, and
  file checksums, then publishes the same bytes. It must not compile.

All PR checks must pass on the exact head and tree that will be merged. The
resulting `main` tree must match the candidate manifest. The candidate Artifact
contains the IPA, `build-info.json`, `validation.json`,
`candidate-manifest.json`, and `SHA256SUMS.txt`. A Release publishes the first
four files; `SHA256SUMS.txt` remains inside the candidate Artifact for its own
verification.

`workflow_dispatch` on the candidate workflow builds and retains a candidate
Artifact, but never publishes. Only a version-bearing merge to `main` can start
promotion. A maintenance merge runs source and offline checks and plans no
release.

Published tags and assets are immutable. A missing, expired, mismatched, or
invalid candidate consumes the merged build; increment the build and repeat the
PR flow instead of substituting a local package. `BARK_URL` is an optional
repository Secret used by a separate best-effort notification job. Package
validation and device acceptance remain separate from source tests.

Do not print machine identities, proxy URLs, tokens, cookies, passwords, or
notification keys in public logs. Update the current release scope only after
reviewing the complete source change; preserve frozen baseline manifests and
third-party notices.
