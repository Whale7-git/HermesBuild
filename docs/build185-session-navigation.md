# Hermes 2.36.0 / build185 — first paint and navigation

Baseline: build184 main `754df44cddf79b285b52f3803c69614a844cb1f4`.

## Changes
- On entering a Session, display a bounded (60-row) **confirmed**, instance/account/session-scoped disk history before waiting for the network GET.
- Restore saved collapsed rows and attempt to navigate to the last reading anchor early **only when that exact anchor is in the displayed cached window**. Existing post-GET and paginated restoration remain authoritative.
- Reuse the same idempotent cache warmup in the normal model load path; no duplicate disk I/O after an early preflight.
- Avoid republishing unchanged ordered session lists on successful background refresh. Metadata, task observation, stale-scope protection and refresh clock still update.
- Add opt-in timing for cache warmup, separate from first UIKit paint.
- Regression tests cover one-shot prewarm, no GET/POST/attach before authority, fail-closed offline state, successful authoritative refresh and performance metric separation.

## Invariants and limitations
No schema, Bundle ID, credential, run/POST/STOP/queue or persistent account-scope changes. Cache remains display-only and cannot authorize sends. No speculative reuse of active NativeChatModel across scopes or prefetch of private sessions. Existing list caching, read-position store, history paging and gestures are preserved.

This is a focused navigation-latency change, not a measured claim of iPhone frame rate or a promise of instant first paint. Real-device comparison still needs opt-in capture.
