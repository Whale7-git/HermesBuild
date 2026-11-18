---
name: ios-performance-diagnostics
description: Diagnose HermesBuild long-chat scroll, streaming layout, keyboard and memory performance with existing in-app telemetry and comparable runtime evidence.
---

# Hermes iOS performance diagnostics

## Reuse existing instrumentation

Read `ChatPerformanceRecorder.swift`, `ChatPerformanceStatistics.swift`, `ChatPerformanceView.swift`, `ChatRenderScheduler.swift`, `ChatStreamPacing.swift`, `ChatRenderBudget.swift`, `StableChatScrollView+Geometry.swift`, `ChatGeometryPlan.swift`, `ChatTimelineProjection.swift` and `ChatMarkdownWorker.swift`.

The in-app "体验诊断" recorder uses opt-in process-local sampling and bounded geometry-only traces. It is not a crash reporting service and its display-link callback cadence is **not** measured physical FPS or system dropped-frame rate. Do not mislabel these metrics.

## Reproducible protocol

- Record exact commit/build, device, iOS version, display settings, Dynamic Type, app appearance, low-power state, temperature if known, conversation size and workload.
- Measure on the same long conversation: 20 seconds vertical reading, repeated keyboard transitions, then a fixed local stream/render case; repeat comparable trials. Do not log message bodies, identifiers, keys or network credentials.
- Compare median and tail stage latency, loaded rows, measured heights, attached hosts, sampled footprint and unexpected geometry adjustments. Inspect SwiftUI/UIKit main-thread work with Instruments when an Xcode runtime is available.
- First isolate source: view invalidation, message diffing, geometry rebuild, markdown work, attachment decoding, network latency or excessive retained state. Do not assume high CPU or stutter is caused by SwiftUI without timing evidence.

## Output

Report baseline/after numbers with source and collection method; differences without comparable samples are hypotheses. Recommend one minimal change with a measurable criterion and a rollback plan. Keep profiling off during normal use. Never introduce background upload/third-party telemetry without an explicit privacy and implementation decision.
