# Hermes 2.30.0 / build179 runtime safety contract

## Scope and single authority

This release makes the existing `ChatPhase` authoritative for chat activity and
`ChatRuntimeCoordinator` authoritative for the cross-cutting terminal/queue
decision. It does **not** introduce an independent second mutable state machine.
`NativeChatModel` remains a `@MainActor` controller: all IO callbacks are
rechecked against the immutable Run context (instance scope, session, Run ID
and local revision) before updating the currently mounted conversation.

## Non-negotiable invariants

- POST acceptance and STOP acknowledgement are not terminal proof.
- STOP intent takes priority over any simultaneous SSE `done`/`stream_end`.
  A terminal SSE frame alone may not lift the STOP lock or flush queued turns.
- Only the matching Run status plus a consistent final read-only history GET
  can release the STOP lock. An unresolved history stays locked.
- After network failure or App suspension, a recovery attempt is GET-only;
  no original chat POST and no second STOP may be replayed.
- Automatic queue dispatch requires a safe, matching terminal event, a
  confirmed final history, and neither a user pause nor a recovery pause.
- The user's manual pause is stored separately from the queued turn records,
  scoped by instance/account/session. Storage failure fails closed.
- Cross-instance, cross-session, stale Run and stale generation callbacks are
  rejected. Failed/unknown evidence never becomes permission to send.

## Network protocol boundary

`GatewayBackend.probeActiveRun` validates both Run ID and Session ID before
recognizing an explicit completed/failed/cancelled/interrupted outcome. The
iOS client cannot establish exactly-once execution without a server-side
idempotency key and durable Run journal; uncertain POSTs remain locked and
require explicit reconciliation, not speculative retries.

## Verification

`tests/model/PhaseTransitionTests.swift`: exhaustive STOP, identity,
terminal-frame, final-history and queue-pause combinations.

`tests/model/SendSafetyTests.swift`: controlled STOP/SSE concurrency,
foreground resumed STOP verification, isolated durable user pause, original
POST/STOP call count, and existing delivery/queue regression fixtures.

`tests/run_container.sh`: existing offline suite; PR candidate workflow
separately verifies the macOS iPhoneOS binary. Real-device UI performance is
not asserted by the offline suite.

## Explicitly out of scope

No server deployment, WebUI modifications, third-party dependency rewrite,
IPA build-chain rewrite, or automated replay of an uncertain POST. UI
scrolling/keyboard architecture from build178 remains intact.
