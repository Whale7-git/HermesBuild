# Hermes 2.35.0 / build184 — long-conversation performance

Base: released build183 main `7da93aeecc3ab6e1af1f8e859f8e534ce9bd011d`.

## Applied, measurable changes
- `ChatProcessPlan.make` indexes anchored tools by turn in one pass instead of scanning every tool for each completed turn. The first eligible process anchor is chosen in transcript order rather than Dictionary order.
- `ChatTimelineProjection` caches tool-to-row ownership during structural projection. Tool payload updates reuse that mapping and the existing row index, and combine structural identity checks into one pass.
- `ChatMarkdownWorker` maintains a cumulative UTF-8 count per frozen segment so streaming parse reuse accounting does not rescan every prior segment.
- Adds a 450-message, 180-tool, 150-turn deterministic timeline regression fixture with measured projection time. Wall-clock timing is informational, not an unstable CI threshold.

## Preserved invariants
No change to sending, STOP, queue pause, terminal statuses, backend API, instance credentials, session identity, UserDefaults schema, browser, or release workflows. The normal history paging, presentation anchors, and streaming tail fast path remain in place.

## Verification
The full offline and source check suites and one macOS IPA build must pass on the same final PR head; device performance is not claimed before device measurements.
