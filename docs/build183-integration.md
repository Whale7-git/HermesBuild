# Hermes 2.34.0 / build183 — reliability and task-state fixes

Base: published build182 main 548bff4600b3f9a94726c24faef3fd3f9bd6ff1e.

## Session creation
- Opening another Session, closing the Session page, or switching scope
  revokes an older create request's right to alter currentSessionID.
- If a stale or partially completed request returns a concrete remote SID,
  store the opaque ID in a 32-entry, instance/account-scoped recovery list.
  The ID becomes a non-authoritative placeholder if it belongs to the current
  scope. Successful authoritative list refresh eventually replaces the row.
- The usual new-Session action now inserts a placeholder immediately too.
- Unknown network outcomes without a returned SID are explicitly ambiguous:
  the UI asks for read-only Session-list verification, never auto-retries.
- A failed protected draft write does not send the message; the known Session
  ID is retained, and typed text stays in the home workspace.

## WebUI model selection
- WebUI's /api/session/new endpoint has no model argument. For home-selected
  models, create a session without claiming a model selection, then submit the
  provider-aware /api/session/update request and GET authoritative history.
- Only when Session ID, model ID AND specified provider match does the iOS
  client arm automatic first-turn POST. If any step fails, it keeps the
  recoverable SID and informs the user; it never sends with the wrong model.
- Gateway model creation keeps its prior model-ID path; ambiguous IDs are
  rejected before remote mutation. Model labels no longer guess between
  identically named IDs from different providers.

## Task consistency
- Persist per-signal observation versions while retaining the legacy
  observedAt field and accepting build182 records with no new field.
- Adding or removing an unrelated signal does not revoke recoveryIssue
  acknowledgement; removal and later return of that signal starts a new
  version and requires new acknowledgement.
- Task center, home sections, drawer rows and accessibility labels read one
  filtered snapshot. Running/approval/verification server facts are not
  cleared by a recovery acknowledgement.
- Corrupt task observation data is distinguished from genuinely empty
  storage, preserved without overwriting, and surfaced in the drawer with
  an explicit clear action.
- Task-ack persistence verifies readback and shows warning on failure.

## Tests & limitations
- Controlled late Session create tests: navigate existing Session, close page,
  switch instance, and confirm old SID remains in original scope only.
- WebUI model/provider setup + authoritative history fixture.
- Legacy/new task JSON, unrelated signal, reappearance and corruption tests.
- Offline tests and macOS iPhoneOS candidate build do not substitute for
  real-device interface testing.

A remote create that times out BEFORE returning an ID cannot be linked with
certainty without server idempotency support. No automatic retry, remote
deletion or guessing from message text is introduced. Approval/clarify card
lifecycle and completion-notification final-only cases remain investigation
targets until a complete event/history fixture proves a defect.
