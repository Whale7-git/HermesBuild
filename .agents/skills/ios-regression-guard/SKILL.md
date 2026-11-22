---
name: ios-regression-guard
description: Map HermesBuild UI, reliability and performance changes to existing Swift/Python tests and device evidence without imposing a release gate.
---

# Hermes iOS regression review

Read current `AGENTS.md`, `tests/run_container.sh`, `.github/workflows/hermes-offline-diagnostics.yml` and `.github/workflows/hermesshell-single-build.yml`. Do not restore removed source inventory scripts or historical scope manifests.

Run focused tests first, then the full applicable suite when useful. The complete local suite is `bash tests/run_container.sh`; GitHub independently runs four Ubuntu diagnostic shards (`core`, `recovery`, `interface`, `media`) plus Python checks. Tests compile Swift units but do not build an IPA.

For each fix report the observed scenario, owning symbols, exact commit/SHA, test commands and actual outcome: PASS, FAIL, NOT RUN, or DEVICE PENDING. Tests should be meaningful rather than passing placeholders. Preserve POST non-replay, account/Session/Run identity and stored state.

**All diagnostic results are informational**: a failed or unavailable test does not block product merge/Release. Track failures honestly in Issues and continue repairing. Only actual IPA build and immutable Artifact integrity affect whether there is a publishable binary.

The candidate workflow compiles a single macOS IPA; promotion reuses identical bytes. Do not introduce duplicate IPA builds, privileged tooling or external runners. Real-device interactions are separate evidence.
