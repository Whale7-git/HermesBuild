# Hermes iOS build190 chat-experience preflight (build189 parallel research)

Baseline: published build188 / main `2936de7285e2fe7ea3926e4f8d7ca5c546cdf429`.

This line is **research only**: no shared runtime file or release metadata is changed in the build189 feature branches.

## Source-backed areas to measure

| Surface | Relevant implementation | Required observational test |
| --- | --- | --- |
| Streaming and viewport | `StableChatScrollView.swift`, `StableChatScrollView+Coordinator.swift`, `ChatScrollState.swift` | Text growth must not dislodge a manually reading user; preserve send-turn anchor and back-to-latest |
| Long Markdown and tools | `ChatRenderScheduler.swift`, `ChatTimelineProjection.swift`, `ChatMessageViews.swift` | 145+ tool records, code fences and nested markdown; capture scroll jumps and memory |
| Keyboard and drafts | `NativeChatView+Composer.swift`, `ChatComposer.swift`, `ChatDraftStore.swift` | Repeated keyboard show/hide and multiline expansion; unchanged draft across host switch |
| Attachments | `AttachmentViews.swift`, `AttachmentInteractionState.swift` | No cross-host attachment path reuse; failed uploads retain selectable draft |
| Run visibility | `NativeChatModel+Stream.swift`, `NativeChatModel+Control.swift` | A view detach should not POST/STOP and must not report a running Run as completed |

## Release gate for build189

Build189 only changes source-confirmed navigation and cache consistency and adds long-run regressions. Do not use build189 to silently refactor message cells, WebUI/Gateway protocols, queue semantics, or attachment transport. Build190 should scope UI modifications from actual iPhone screenshots/diagnostics; static source inspection does not establish real-device drag ergonomics or keyboard layout.

## Parallel integration

Navigation, cache and run regression branches own disjoint file changes. Only the integration branch owns `README.md`, `Resources/Info.plist`, `release.json`, and `tests/release-scope-build189.json`. Individual development branches do not open PRs against main because the current candidate workflow is triggered by every pull request targeting main, which would cause unnecessary IPA compiles.
