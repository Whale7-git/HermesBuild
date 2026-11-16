# Hermes 2.37.2 / build188 — navigation, cache and refresh

Base: published 2.37.1/build187 \`main\` 4e38c1e73f79125bfc06e118992e8cb7d3397458.

## Changes

- Root browser navigation now uses a page stack and source (.drawer/.chat) instead of the former browserFromSingle booleans. Direct drawer -> all -> back returns to the mounted drawer; single -> all -> back returns to single.
- Browser selection of a native Session keeps its originating browser mounted. In-session right swipe returns to the same browser, preserving its query, filter and scroll position; another swipe returns to drawer or home by the source. Native Session identity remains scoped and verified by AppState; no POST on navigate/back.
- Rightward card return can originate in non-edge page content (with a strong horizontal-dominance direction threshold). Partial drags still rebound. Vertical scrolling and leftward gestures are excluded by policy; real-device interaction with text-selection/horizontal subviews must be checked by the user.
- RootView owns UnifiedSessionModel and query/filter state. Cache keys isolate instance, endpoint identity and account, plus query for refresh timestamps. Successfully fetched rows stay available after browser view teardown. A recent scoped list timestamp from AppState can seed a fresh first visit.
- Automatic entry calls refreshIfNeeded: no GET during a fresh 5-minute TTL, background revalidation of stale sources within a sliding three-source cap, no top spinner when a verified snapshot exists. First-ever empty cold entry may show one loading indication.
- Pull-to-refresh remains a manual forced request with native refresh indicator; explicit menu refresh has its own progress state. Same in-flight request is coalesced.
- An existing AppState list update after Gateway run-state events adopts updated rows into the unified model without a redundant cross-host request; non-active sources are not claimed to have continuous push subscriptions. Server-side full-body search remains WebUI-only; Gateway searches titles/previews.
- Automatic network failures are non-modal: previous rows survive, per-host errors and retries remain available.

## Boundaries and known constraints

- Does not alter the server API, backend deployment, Keychain, Session/Run/STOP/queue semantics, POST, scroll anchors, historical paging, SideStore Bundle ID, or official build workflow.
- The TTL is an entry-refresh policy, not a guarantee of live remote run-state for inactive hosts.
- Read-only GET/search tasks obey timeout and generation ownership; no silent outbound POST.
- Real-device gesture ergonomics and memory pressure are unverified until an iPhone acceptance test.
