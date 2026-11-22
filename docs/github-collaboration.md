# HermesBuild GitHub workflow (current)

Use `main` as the product source of truth. Develop in short-lived branches, open a PR and keep all code and behavior changes reviewable by commit. The one product candidate is compiled on macOS; no local IPA substitution.

## Independent workflows

| Workflow | Responsibility | Blocks product Release? |
|---|---|---|
| `hermesshell-single-build.yml` | Compile and package the exact candidate IPA once; upload immutable Artifact | **Only if IPA cannot be built or verified** |
| `hermes-offline-diagnostics.yml` | Four parallel Swift shards, Python/static diagnostics, full logs and visible failure status | **No** |
| `simulator-probe.yml` | Manual-only Simulator UI diagnostics (`Actions → Run workflow`, choose suite); no PR/daily/post-release auto-trigger | **No** |
| `verified-release-automerge.yml` | Automatically merge a valid version-bumped product PR after candidate success | No Issue, source hash, test or manual-approval gate |
| `hermesshell-single-promote.yml` | Select exact PR candidate and publish identical bytes; best-effort Bark notification | Actual Artifact identity/integrity required |

A product PR does not need a complete Issue matrix or green diagnostics to ship. When tests fail, report failure, continue the corresponding repair and do not claim the Issue fixed. No source baseline, release-scope hash manifest, triple-green workflow, or hold-label rule is used.

The protected boundary remains: PRs changing `.github/workflows/`, privileged scripts or governance files are **maintenance PRs** and require an explicit trusted agent merge. Automatically merged product PRs cannot change scripts that hold write permissions.

## Artifact provenance

The candidate Artifact includes the unsigned IPA, `candidate-manifest.json`, `validation.json`, `build-info.json` and `SHA256SUMS.txt`. Promotion compares expected commit/tree, archive digest and published bytes. It never rebuilds the IPA. Publishing wrong bytes or an existing tag is an error, not a cosmetic diagnostic.

Run `bash tests/run_container.sh` for a local full suite; CI shards are independent jobs on Ubuntu. Debug test failures using shard-prefixed START/FAIL timestamps. Use `release.json` and GitHub Releases for version truth.

## Issues

GitHub Issues are the active backlog. The project manager tracks the entire open set and delegates disjoint repairs. Use `Fixes #N` only when an issue genuinely meets its full acceptance criteria; plain `#N` for partial or externally blocked items. Simulator failures and real-device findings are distinct forms of evidence.

Third-party licenses, Gateway protocol contracts and source security invariants remain in force; historical build-specific plans are visible in Git history, not in the active documentation.
