# Hermes 2.38.1 / build191 — navigation and unified refresh correctness

Base: published build190 main `c2bf19a420e52d9db7cc957b8b758a8408ca7a0f`.

## User journeys fixed

1. Sidebar -> All Instances -> select a Session -> top-left hamburger now opens the sidebar. Previously `openSidebar()` unconditionally refused while `browserOpen`, even when a selected conversation was visibly stacked above the browser. A direct drawer action retires that browser route; it does not alter the Hermes run, queue, draft, or Session identity.
2. Select a Session from All Instances -> top toolbar New Chat now retires the stale browser return route when the current Session is explicitly closed. Ordinary Session changes retain their expected back route.
3. Toolbar back labels on single-instance browser pages distinguish returning to drawer versus returning to chat.
4. Browsers kept behind the selected chat cannot intercept touch or VoiceOver focus; the page remains mounted to preserve query/filter/scroll context for the ordinary right-swipe back.
5. Automatic stale-host refresh followed by explicit Refresh All now upgrades the in-flight request's scheduled host set, using its existing three-host GET sliding window. Any previously covered host is requested just once, and the returned shared task only finishes when the appended hosts have completed. No new/duplicate POST.
6. A failed instance displayed on reentering a fresh cached browser can still be retried even though its previous read task has been cancelled. Retry validates `cachedKey`'s scoped instance / endpoint / account and query, not the obsolete in-flight `requestKey`.

## Regression coverage

- Pure navigation checks: browser-selected chat hamburger is enabled, bare browser is guarded, new draft retires old route, normal Session retains its browser context.
- Async source fixtures: partial -> forced full GET upgrades and includes all hosts with one GET per host; cached reentry after failure permits scoped one-host retry.
- Existing source/release scope, 145+ tool long-session, Send/STOP queue, scroll geometry, attachment and Swift offline regressions remain unchanged.

## Boundaries

No backend protocol changes, new credentials, Session/Run stop semantics changes, automatic POST, bundle ID change or rolling rebuild. The full-width right-swipe recognizer and live remote-run status semantics are not rewritten without iPhone evidence. Physical device acceptance not claimed.
