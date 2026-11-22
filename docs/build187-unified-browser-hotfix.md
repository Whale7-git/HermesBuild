# Hermes 2.37.1 / build187 — Unified browser navigation/refresh hotfix

Base: released 2.37.0/build186 main 7f377c30e2bb787acf08aac58f709382a7dc307f.

## Scope
- Fix the stack of the full-page browser. Single Instance -> All Instances now returns to Single Instance from **both the toolbar button and the left-edge right-swipe gesture**. Direct All Instances entry returns to chat. The actual previous Single Instance page is mounted below the swiped card to keep the gesture visually consistent.
- Widen the existing rightward back-gesture start edge from 24pt to 32pt, still preserving vertical scrolling and horizontal text selection outside the edge. A leftward swipe is not an iOS navigation-back gesture; existing leftward interactions are unchanged.
- Consolidate automatic, pull-to-refresh and menu refresh through one in-flight keyed task: same scoped query joins, no duplicate GET. Changing query or scoped instances replaces the generation; obsolete results never publish.
- Keep verified visible rows during a same-query refresh and a failed request. A failed host has its own error text and **Retry** control, which does not clear or refetch other hosts.
- Use a sliding three-host concurrency window, rather than waiting for a whole batch of three before the fourth host starts. Both WebUI full-body searches and Gateway list reads receive a 20-second per-source cancellation-aware deadline. A remote transport must cooperate with cancellation for a timeout to complete promptly.
- Display **全部实例读取失败** or **部分实例不可用** rather than falsely declaring no Sessions after failed requests.

## Boundaries
Only Unified Session Browser, its source model, host-page navigation, pure gesture policy and tests are affected. Existing server-side full-body behavior, instance/account/session identity checks, current-instance drawer, chat viewport, POST, STOP, queue, streaming, run state, Keychain and Bundle ID remain unchanged.

## Validation
- Offline regressions cover cross-instance return-stack policy, gesture edge, duplicate refresh joining, retained rows, per-host recovery, cancellation, bounded full-body/list timeout and sliding-slot scheduling.
- Source and scope validation, full offline Swift suite, a single macOS IPA candidate and exact-candidate Release promotion must pass before publishing.
- No physical-device gesture acceptance or latency percentage is claimed by offline/CI evidence.
