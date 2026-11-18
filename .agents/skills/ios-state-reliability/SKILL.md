---
name: ios-state-reliability
description: Audit HermesBuild asynchronous chat state transitions, session identity, uncertain sends, run completion, queue pause ownership and recovery races.
---

# Hermes iOS state and concurrency reliability

## Read the existing model, do not replace it

Start with `ChatPhase.swift` (mutually exclusive phase, orthogonal ChatFacts, ChatRunContext), `NativeChatModel.swift`, `NativeChatModel+Send.swift`, `NativeChatModel+Stream.swift`, `NativeChatModel+Control.swift`, `ChatRecoveryCenter.swift`, `ChatQueueManager.swift`, `ChatSendQueue.swift`, `GatewayRunStore.swift`, `AppState.swift` and `SessionTaskCenter.swift`.

Build a state-transition and ownership table for every proposed correction: trigger, prior phase/facts, next phase/facts, instance/account/session/run identity, who can cancel, persisted data, UI representation and stale callback behavior.

## Non-negotiable invariants

- Never replay a possibly accepted original POST just because a response, stream or connection timed out.
- A stale network callback must not mutate a different instance, account, session or run. Inspect identity both before and after awaits.
- Keep user-paused queue and fault-paused queue intent distinct; recovery must not silently resume user-paused work.
- Keep "stop accepted" distinct from confirmed terminal completion. Until proof of terminal state, retain conservative send locks.
- Completed, failed, cancelled, interrupted and unknown are different outcomes; unknown must not be coerced to success.
- A terminal history refresh is read-only and must not accidentally dispatch an old queued message.
- Preserve draft and pending-send state through app suspension, account switch, view teardown and storage failure.
- Server-labelled internal events are not equivalent to ordinary user messages; do not classify user text by a pasted envelope alone.

## Targeted regressions

Start with `tests/model/PhaseTransitionTests.swift`, `tests/model/SendSafetyTests.swift`, `tests/model/PendingRecoveryTests.swift`, `tests/model/ActivityRecoveryTests.swift`, `tests/model/SendModeTests.swift`, `tests/scroll/` and matching gateway tests. Add focused tests for out-of-order responses, noncooperative cancellation, network uncertainty, terminal misclassification, instance switching and long history with many tool rows only if existing coverage is insufficient.

For every suspected race, provide a timeline of actors/events and show the missing guard. Distinguish static concern from a reproduced failure. Avoid broad rewrites of NativeChatModel unless the measured defect demands them.
