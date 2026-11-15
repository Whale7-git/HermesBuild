# build160 · Chat viewport performance and behavior acceptance

This is a repeatable **measurement plan**, not a claim of device testing. The developer may run it on IPAs produced by the current candidate workflow. Keep the compared builds, device model, display setting, test data and network conditions identical.

## Captures

For each history size **100 / 500 / 2,000 messages**, sample at least 3 fresh runs on the same iPhone:

1. Enter a previously loaded session and record first visible row, initial anchor and first paint.
2. Start a reply with many short tokens. Observe the visible question's top coordinate while the latest assistant row grows.
3. Scroll manually to the middle during streaming. Continue 20+ token updates; confirm the view stays detached and only an unread indicator appears.
4. Jump to latest, dismiss/open keyboard, rotate where supported and verify no non-user-command jump.
5. Expand/collapse 1 then 8 tool cards while detached; preserve the first visible message plus its within-row position (allow 1pt rounding).
6. Prepend two pages of older history from a mid-conversation anchor. Assert the same message remains visible at the same screen coordinate.
7. Scroll horizontally through any carousel to its rightmost edge. Verify clipping/rounding and gesture ownership, including an interrupted drag.
8. Select text in the growing reply while streaming. Verify selection and drag handles remain stable.

Collect the built-in diagnostic timing summary for **时间线投影**, **差异协调**, **消息几何布局**, **提交布局**, **发布→提交** and **显示回调间隔**; retain p50/p95/max and sample count, the number and magnitude of uncommanded scroll offsets, and peak mounted hosts. Compare identical runs to build159, not to screenshots or simulated frame rates.

## Acceptance

- No change to message order, role, tool-call association or session resume/paging behavior.
- No non-command scroll offset adjustment over 1pt while the user is actively dragging, selecting text or interactively dismissing the keyboard.
- Detached reading anchor stays on the same row through token growth, tool-card height changes and two older-history prepends.
- Confirm the footer and composer remain accessible and the rightmost carousel/card preserves continuous corners.
- No regression in the measured p95 of projection, reconcile or commit layout versus the build159 baseline. Log measured values if a path worsens.
- Every local pure test in timeline, scrollgeometry and performancestats must complete; real-device UI acceptance is separate and cannot be inferred from these tests.

## Design boundaries

Only source performance and test files change on this branch. It does not modify the runner, build scripts, release workflow, Hermes API, sends, caching, account scopes, or the delivery recovery contract. If a test reveals an independent UI defect, isolate it into a separate commit with its own repro and acceptance conditions rather than changing multiple subsystems speculatively.
