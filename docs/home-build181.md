# Hermes 2.32.0 / build181 — home conversation contract

## Navigation

The root chat card still remains mounted behind the drawer; the full-page
session browser remains a separate push surface. The home view exists only
when no Session is selected. The **New chat** action opens a local draft
workspace; app launch or tapping New chat never silently creates a remote
Session. The Search icon opens the full Session browser in search mode;
the drawer provides a direct task-center entry.

## First message and safety

1. The home composer shares `ChatDraftEditor`, iOS keyboard behavior, input
   height and controls with the conversation composer. Its draft is scoped
   to the current instance and account in protected local file storage.
2. When Send is tapped, one session creation is accepted (duplicate taps
   are locked), then that specific session's draft is securely persisted
   and verified **before** navigation. An ambiguous model identifier
   shared by providers is rejected rather than silently selected.
3. An in-memory `HomeTurnClaim` contains immutable instance/account/
   session identity. The newly mounted chat page may claim it **once**
   only after successful history load and send-safety checks. It then
   uses `NativeChatModel.send()`, never a second HTTP POST implementation.
4. The claim is consumed before awaiting network operations, preventing
   automatic POST replay across view reconstruction, suspension or restart.
   A failed/unknown outcome retains the saved draft and follows the
   existing manual reconciliation rules.
5. If the home Plus button is used, the new Session receives the typed
   draft but no automatic POST; attachments are added through the
   existing session-owned uploader and sent explicitly afterwards.
6. Switching instance/account flushes the departing home draft to its
   original storage and rejects callbacks from the stale scope.
   Creation or storage failure leaves the original home text in place.

## Known boundaries

The backend's session creation endpoint does not provide a durable
idempotency key; a timed-out create may leave an unused empty Session.
The client never retries automatically. This release does not change
server-side protocol, chat Run/STOP safety, authentication, uploaded
attachment storage, or existing Session/Model records. iPhone visual
and keyboard behavior remain device-level acceptance, not CI claims.
