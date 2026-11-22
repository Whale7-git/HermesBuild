---
name: ios-regression-guard
description: Map HermesBuild UI, state and performance fixes to existing lightweight gates and offline tests while separating CI, IPA and device acceptance.
---

# Hermes iOS regression guard

## Follow, do not duplicate, the current test pipeline

Read `AGENTS.md`, `tests/run_container.sh`, `tests/check_navigation_contract.py`, `tests/check_swiftui_modifiers.py`, `tests/verify_source.py`, `tests/sourcegate/main.py` and `.github/workflows/hermesshell-single-build.yml`.

Existing local/CI entries:
- `python3 tests/verify_source.py`
- `python3 tests/check_navigation_contract.py`
- `python3 tests/check_swiftui_modifiers.py`
- `python3 tests/test_swiftui_modifiers.py`
- `python3 -m unittest discover -s tests/releaseautomation -p 'test_*.py' -v`
- `bash tests/run_container.sh` (Swift toolchain required).

Determine the *smallest relevant* tests first, then the complete applicable suite before merge. Do not claim tests ran unless results are available from an actual invocation or verified workflow run. Tests may be extended in feature PRs, but audit-only changes should not impose a new CI check or compile.

## Traceability

For every fix require: failure scenario; invariant; owning source symbol; added/updated existing test; command and outcome; suspected device-only edge; version/commit checked. Use explicit labels **PASS**, **FAIL**, **NOT RUN**, **DEVICE PENDING**.

Prioritize isolated tests for scroll-state hysteresis, geometry, restored reading, session ownership, queue edit/pause, uncertain send, terminal state, interrupted runs, draft persistence and navigation cancellation. Keep navigation route coverage intact.

## Release boundary

The existing PR workflow runs source, offline and one iPhoneOS candidate compile; main promotion reuses that candidate. Do not add separate IPA builds, SwiftPM caches, external runners, release branches or new release scripts. Audit-only PR should keep `release.json`, `Resources/Info.plist` and README version header unchanged. If a requested change needs a published binary, follow the repository's existing release engineering Skill and exact validated candidate. Real-device UX results remain separate even when CI is green.
