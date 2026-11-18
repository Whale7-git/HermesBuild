---
name: ios-interaction-audit
description: Review HermesBuild chat reading, keyboard, streaming, gesture ownership, navigation, queue interactions and user feedback for measurable iOS UX regressions.
---

# Hermes iOS interaction audit

## Source map

- `ChatComposer.swift`, `ChatDraftEditor.swift`, `NativeChatView+Composer.swift`: text input, focus, model selection, draft persistence and send/stop.
- `StableChatScrollView.swift`, `StableChatScrollView+Coordinator.swift`, `ChatScrollState.swift`, `ChatGeometryPlan.swift`, `ChatReadingPosition.swift`: reading anchors, scrolling and viewport updates.
- `RootView.swift`, `SessionDrawer.swift`, `UnifiedSessionBrowser.swift`: drawer/card back gestures, navigation ownership, modals and instance switching.
- `ChatSendQueue.swift`, `ChatQueueManager.swift`, `SessionTaskCenterView.swift`, attachment views: pending-action visibility, edit/remove, cancellation and recovery feedback.

## Scenario matrix

1. New session -> type one/multiple lines -> send -> user turn stays a stable visual reference during streaming.
2. Read old messages while the assistant streams -> text height changes -> preserve reading position; explicit "back to latest" returns correctly.
3. Focus/dismiss keyboard, rotate and resize while reading -> no accidental follow re-attachment or draft loss.
4. Side drawer vs full-card page vs modal sheet -> gesture owner is unambiguous; settling/cancellation does not drop underlying conversation.
5. Submit, stop, queue, edit queue in place, reconnect and switch instances -> status/action labels match the actual state; never imply completion before acknowledgement.
6. Long history, collapsed tool calls, inline images, text selection, search and pagination -> no anchor or focus corruption.

Cross-check relevant tests (`tests/scroll/`, `tests/scrollgeometry/`, `tests/conversationreading/`, `tests/model/`, `tests/discovery/`) before suggesting new fixtures.

## Evidence protocol

Use code to explain possible paths, screenshots/recordings to verify visual behavior, and reproducible device steps to establish tactile defects. Report each scenario as source-reviewed, offline-tested, simulator-tested, device-tested, or not tested. "Compiles" is not a UX pass. Where no device runtime exists, write a short, deterministic acceptance script rather than guessing the result.

Do not rearrange major layout or remove intentional gestures in an audit-only task. Fix mode requires explicit scope and a small PR.
