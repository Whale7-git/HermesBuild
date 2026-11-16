# Hermes 2.37.0 / build186 — Cross-instance session browser

Baseline: released build185 main 7ea2ed62244df295ed05f25680f2f872f68336e3.

## UI scope
- Drawer: one **全部实例会话** entry; existing single-instance chat and drawer controls remain intact.
- Full-page browser: new all-instances view, shared keyword search, source labels, **全部 / 运行中 / 置顶 / 近7天** filters, per-host progress and partial-error rows.
- Switch from all-instances to the existing single-instance browser without switching the current live chat.
- The home search entry opens all-instances search when more than one instance exists.

## Read-only discovery
- Existing instance/account-scoped in-memory snapshots show immediately when known.
- At most three hosts fetch concurrently in read-only waves, with per-source failures that do not erase other rows.
- WebUI uses its genuine server full-body search; Gateway searches titles/previews from GET session lists only. No fabricated remote Gateway full-text capability.
- Async search generations reject stale results; account/endpoint changes invalidate scoped snapshots.

## Navigation safety
- No host switch during searching. Only a user selection is authorized to switch the active host and open a native Session.
- Navigation checks *instance UUID, normalized endpoint identity, account scope and Session ID* before changing state.
- Same Session ID on two hosts produces separate entries; wrong/stale account or endpoint cannot navigate.
- No new server API, persistence schema or migration; no changes to run, queue, STOP, POST, streaming, or chat anchoring.

## Verification
- Unit regressions: identical cross-host Session IDs, cache isolation, fail-closed stale routing, partial outages, real WebUI full-body vs Gateway local search, cancellation, three-host concurrency bound.
- Source/release gate, full Swift offline suite, one candidate IPA compilation and automatic promotion all required before release.
- No physical-device interaction or latency claim without measured evidence.
