# Hermes iOS quality baseline — 2.46.0 / build205

**Pinned source:** `Whale7-git/HermesBuild/main` at `98166bf233e8191439822d252ae32feaf7045bd2` (verified 2026-11-19).
**Audit mode:** initial architecture and coverage inventory; this document does **not** assert user-facing bugs or report test execution.
**Purpose:** direct future quality reviews to the existing implementations before proposing another framework.

## Verified inventory

| Concern | Existing implementation | Existing coverage / diagnostic | First review question |
| --- | --- | --- | --- |
| Design system | `AppTheme.swift`, `DesignComponents.swift`, `HermesEmptyState.swift` | `tests/check_swiftui_modifiers.py`, `tests/experience/` | Do the same actions use the same tokens, accessibility roles and feedback across screens? |
| Navigation | `RootView.swift`, `SessionDrawer.swift`, `UnifiedSessionBrowser.swift` | `tests/check_navigation_contract.py`, `tests/discovery/` | Do card/back gestures, full browser, modal presentation and instance switch preserve ownership? |
| Composer | `ChatComposer.swift`, `ChatDraftEditor.swift`, `ChatDraftStore.swift` | `tests/drafts/`, `tests/input/`, `tests/model/` | Are focus, queued editing, draft flush and send/stop feedback consistent? |
| Scroll and rendering | `StableChatScrollView*.swift`, `ChatScrollState.swift`, `ChatGeometryPlan.swift`, `ChatRenderScheduler.swift` | `tests/scroll/`, `tests/scrollgeometry/`, `tests/conversationreading/`, `tests/renderscheduling/` | Can keyboard/layout changes steal the reading anchor during a long stream? |
| Run reliability | `ChatPhase.swift`, `NativeChatModel+Send.swift`, `NativeChatModel+Stream.swift`, `ChatRecoveryCenter.swift`, `ChatQueueManager.swift` | `tests/model/PhaseTransitionTests.swift`, `SendSafetyTests.swift`, `PendingRecoveryTests.swift` | Are stale callbacks, uncertain POST and queue pause guarded by identity/state? |
| Performance | `ChatPerformanceRecorder.swift`, `ChatPerformanceStatistics.swift`, `ChatPerformanceView.swift` | `tests/performancestats/`; opt-in in-app "体验诊断" | Is there comparable runtime evidence for perceived stutter rather than only code inspection? |

## Existing delivery constraints

- Repository `AGENTS.md`: work on a separate short-lived branch; PR into main; do not claim actual iPhone behavior without device evidence.
- Main workflow `.github/workflows/hermesshell-single-build.yml`: source verification, Swift offline regression, one macOS candidate IPA. Promotion is handled by `hermesshell-single-promote.yml`.
- Do not introduce a second build/release path, broad source reformat, additional dependency, new secrets collection or an SDK merely to run audits.
- Preserve `com.whale7.hermes`, Keychain identity, historical paging, collapsed tool calls, right-swipe behavior and uncertain send safety.

## Initial assessment status

| Assessment | Status | Explanation |
| --- | --- | --- |
| Source architecture mapped | **DONE** | Relevant source/test entry points inspected at pinned commit |
| Design inconsistency findings | **NOT VERIFIED** | Requires cross-screen comparison; no defect claimed |
| Scroll / gesture device acceptance | **DEVICE PENDING** | Static contracts cannot reproduce physical gestures |
| Queue and run-state correctness | **NOT VERIFIED** | Existing code/tests identified; no new regression executed for this audit |
| Performance regression | **NOT VERIFIED** | No comparable before/after measurements available in this review |
| Release build | **NOT RUN** | No app or version changes are proposed in this initial baseline |

> **Historical build205 audit snapshot only.** This document does not control
> the current hourly Issue-repair workflow. Use `AGENTS.md` and the live
> `.agents/skills/ios-quality-review/SKILL.md` for fix-mode behavior.

## Recommended first audit pass

1. Run `ios-quality-review` in read-only mode against a newly pinned main SHA; begin with `ios-design-audit` and `ios-interaction-audit`.
2. Use the iPhone device's existing "体验诊断" screen only for reported lag; collect anonymized, consented comparisons without real chat text.
3. Convert confirmed P0/P1 findings into independent minimal fix PRs; add focused tests in the already established test suites.
4. Keep each issue's proof, proposed patch, observed checks and remaining device-only uncertainty separate. The quality Skill files are review instructions, not evidence of passing acceptance.

## Invocation

Ask: `Use ios-quality-review on the latest HermesBuild/main. Audit UI consistency, interaction, state safety, performance and test coverage. Return only evidence-backed prioritized issues; do not change source code or release the app.`

For a targeted report, invoke `ios-design-audit`, `ios-interaction-audit`, `ios-state-reliability`, `ios-performance-diagnostics` or `ios-regression-guard` directly. Skill definitions are in `.agents/skills/`.
