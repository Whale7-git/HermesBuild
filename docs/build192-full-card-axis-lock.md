# Hermes 2.38.2 / build192 — consistent right-swipe ownership

Base: build191 `main` at `dcb8aced62e8fa82bfc4770b3655e68bf02c8e59`.

## Observed source defect and expected user behavior

The ordinary chat page's `ChatDrawerInteraction.shouldTrack` only accepted a pan starting in the first 24pt of the left screen edge, whereas browser cards accepted a rightward pan from the entire card. This made the same right-swipe gesture fail on the main chat.

A full-card back operation must **not** scroll the chat contents vertically as the card moves horizontally. This cannot be guaranteed by `simultaneousGesture` alone: by design, it can run alongside a scroll gesture.

## Implementation

- Enable full-card rightward drawer reveal on ordinary chat, including a draft workspace, while retaining the original return destination for browser and browser-selected chat. The exposed drawer's host switcher is kept outside the close-card gesture's active origin.
- One pure `ChatBackAxisPolicy` sets the dominant rightward pan ratio (1.65x) for chat drawer and pushed-page card return, with regression checks for middle/right-edge start, vertical pan, and leftward pan.
- `ChatCardContainer` temporarily disables descendant SwiftUI scrolling only while a horizontal return drag is active; it automatically re-enables scrolling when the gesture finishes or springs back.
- The transcript uses a UIKit `UIScrollView`; forward the SwiftUI `isScrollEnabled` environment to it, and enable UIKit `isDirectionalLockEnabled`. An initial horizontal pan is not misclassified as manually reading history and does not call the scroll hot path or interrupt the streaming turn's read anchor.
- Keep existing swipe completion thresholds, card geometry, Safe Area clipping, no POST/STOP/queue modification, and the text-selection/zoom attachment implementations. Do not add a forced high-priority pan gesture over child controls.

## Boundaries

Built-in system sheets retain native dismissal rather than pretending to be RootView navigation cards. Nested horizontally scrollable elements can still require physical-device checks for gesture priority. Actual drag frame rate and long-session interaction responsiveness are not measurable by Linux offline tests; they require iPhone observation and, when necessary, an Instruments trace.

## Acceptance

Source gate + release scope, complete Swift offline suite, one iPhoneOS macOS IPA compile on the exact PR head, then merge and promote that candidate unchanged. No real-device acceptance claimed.
