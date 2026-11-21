# Hermes source-local Textual 0.5.0

Upstream: https://github.com/gonzalezreal/textual
Revision: `01b51875a5406eefc95f52a058cb059e7bc94dc4` (0.5.0).
The original Sources/, Package.swift, README.md and MIT LICENSE were copied from
the existing verified build checkout. No binaries or newly fetched runtime
dependencies were added. See UPSTREAM-SHA256.json for original file digests.

Local changes:

> **2026-11-12 更正：** 下面按「改动类别」列了 7 条，但逐字节比对上游
> `01b51875` 后发现实际有 **17 个文件**与上游不同。未在下列文字中单独说明的
> 10 个文件集中在文本选择交互（`TextInteraction/**`）、高亮分词
> （`CodeTokenizer`、`HighlightedTextFragment`）、`BlockVStack`、`TextFragment`
> 与 `Style/Overflow.swift`。以 `patches/` 目录和 `UPSTREAM-SHA256.json` 的
> `modified_files` 为准，文字说明仅作意图解释。


1. Package.swift omits upstream-only snapshot test target/dependency; this copy
   ships the library sources/resources. Existing external runtime versions remain
   locked in the application's Package.resolved.
2. StructuredText.swift adds `init(attributedString:deferCodeHighlightingAfter:)`.
   Prepared content avoids the UI-thread Markdown parse and retains the original
   ONE selection/attachment coordination surface.
3. BlockContent.swift makes individual blocks Equatable to skip unchanged bodies.
   Parent layout still coordinates natural heights; no guessed/frozen pixel sizes.
4. CodeBlock.swift defers Prism highlighting for the active tail's identities.
   Completed blocks and the final document use normal highlighting.
5. WithAttachments.swift extracts the generic view's independent observable model
   to avoid Swift 6.4 isolated-conformance warnings. Resolved documents are matched
   to their input and cancelled resolves are discarded, so late attachment work
   cannot cover new prepared content with an old document.
6. BlockVStack.swift shares actual child measurements between sizing and placement
   for the exact proposal in the current SwiftUI Layout cache generation. Every
   `updateCache` clears those measurements and recomputes collapsed spacing, even
   for same-count content changes. Text environment, inline/highlighter styles,
   locale, direction, scale, overflow and deferred-highlighting boundary also
   invalidate reuse. The proposal LRU holds at most three arrays of sizes, never
   historical documents. This is **not** a persistent streaming-prefix height
   cache: content/subtree updates conservatively measure again. BlockContent and
   the single-document selection/attachment coordinators remain intact.
7. HighlightedTextFragment.swift keys work by attributed input plus language,
   rejects cancelled or superseded generations, and displays a highlighted result
   only for its exact input, theme and text environment. Disappearance invalidates
   pending publication. CodeTokenizer.swift checks cancellation after entering
   the actor, so an already-cancelled queued request does not run Prism. A running
   synchronous JS call is allowed to finish; it cannot publish into newer input.
   Each mounted fragment retains at most one completed input/token result for
   reattachment. Plain or cancelled in-flight work is never marked complete;
   changed input/language discards that result, and appearance changes still
   restyle the matching tokens. There is no cross-model highlighter cache.
   The optional `textualCodeTokenizationDuration` environment hook reports numeric
   synchronous tokenization duration only, excluding queueing, theme styling and
   layout; a nil hook performs no clock reads.

New source-local helpers `BlockMeasurementCache.swift` and `TokenizationWork.swift`
contain the actual proposal-cache and publication/cancellation logic. Their
offline tests run with `bash tests/textualprimitives/run.sh` from the app root,
covering exact-width reuse, invalidation, bounded proposal retention, out-of-order
source/language/same-input generations, queued actor cancellation and disabled
diagnostic overhead. These tests do not execute SwiftUI Layout or JavaScriptCore.

The changes above are the local patch set. Original tests/snapshots are not
included. Application pure-source boundary/publication tests run on Linux; native
Foundation semantic fixtures are available in Settings → 渲染检查 and must run on
an iPhone. Successful cross-compilation does not establish frame-rate or selection
acceptance on a device.


## build32 and build33 selection patch record

The received build32 also modified UITextInteractionView, TextSelectionInteraction,
UIKitTextSelectionInteraction, UIKitTextInteractionOverlay and its AppKit peer to
forward TextMenuActions into the system edit menu. These existing changes are
part of the received baseline; they were not proof that iPhone selection worked.

build33 adds a non-interactive UIKit TextSelectionLayoutUpdater and the actual
TextSelectionUpdateRelay helper. updateUIView always supplies the latest layout;
delivery is coalesced after SwiftUI's update pass and invalidated on dismantle.
LiveTextLayoutCollection and View+TextLayoutCollection now depend on container
size, including an initially empty staging layout. The direct selection overlay
and the original single-document coordinator remain intact. Unknown edit action
selectors fall back to UIKit rather than being denied unconditionally.

Relevant upstream evidence (reference only; no dependency/version upgrade):
- https://github.com/gonzalezreal/textual/pull/71 (same-frame onChange delivery)
- https://github.com/gonzalezreal/textual/pull/88 (size dependency and system actions)
- https://developer.apple.com/documentation/uikit/uitextinput/editmenu(for:suggestedactions:)

BlockMeasurementContext and OverflowMode gain compiler-checked Sendable
conformance. No unchecked concurrency conformance is added.

The 12 headless selection-relay assertions exercise the actual delivery helper,
not UIKit hit testing, SwiftUI preferences, private Text.Layout reflection,
selection handles or pasteboard behavior. Those need an iPhone runtime.


## build35 native text fragments

Hermes opts into textualUsesNativeTextViews at NativeMarkdownView. TextFragment
uses NativeSelectableText for actual non-attachment glyphs, with readonly
UITextView owning rendering, ranges, edit menus and native link activation.
No custom long-press is installed above that view and the reflected document
selection overlay remains disabled. Code/table containers, syntax token colors,
block spacing and their existing copy buttons are retained. Attachment/math
fragments use the original renderer; it is not claimed that these are selectable.

The new TextualSelectionPublication helper coalesces updates while a range is
being selected. Resignation clears stale ranges (so host budgets can unpin) and
releases the newest queued text. A width/content measurement cache avoids
repeated sizeThatFits. Fonts use public UIKit body descriptors plus the current
Markdown heading/code/emphasis semantics; no new private reflection is used.

Selection is local to a text fragment: independent paragraphs, code blocks and
table cells do not share one continuous UITextView range. Hermes keeps its
full-message native source sheet as an explicit fallback for cross-block copy.
Direct selection/scroll handles must still be verified on the user's iPhone.

## build41 measurement keys, token cache and in-memory history window

`BlockMeasurementContext` now also carries `lineSpacing`, `paragraphStyle`,
`codeBlockStyle` and `listItemStyle`. Style environment values are existentials
without `Equatable`/`Sendable` conformance, so each is reduced to a Sendable
type-plus-stored-value fingerprint; reference instances contribute their object
identity, and opaque values may over-report a change. `updateCache` still
invalidates every measurement unconditionally: this round only makes the context
able to tell styles apart before a device A/B is allowed to enable reuse.
`headingStyle`, `blockQuoteStyle`, `tableStyle`, `tableCellStyle`,
`thematicBreakStyle` and the list markers are not part of the context yet and
must not justify reuse. No `@unchecked Sendable` conformance was added.

Streaming prefix reuse was evaluated and deliberately not enabled. A block's
presentation-intent identity is positional: one attributed-string parse assigns
identities in document order, so the identity at a position stays the same when
the text there changes. Even with an unchanged content and context, a completed
block can still change height through asynchronous attachment resolution and
theme-driven token fonts, and custom paragraph/code/list styles may contain
arbitrary views and state. SwiftUI Layout exposes no per-subview subtree-change
signal, so the parent cannot prove that a previous prefix height is still the
natural height. Carrying sizes across `updateCache` would risk clipped or
overlapping text; the provably safe subset is empty, so this change is skipped
rather than enabled behind a guess.

`TextualTokenizationWork` keeps one completed input per mounted fragment and can
now consult a process-lifetime `TextualTokenCache` shared by all code fragments:
an LRU of at most 64 completed results or an estimated 4 MiB, keyed by the exact
`(language, source)` pair, never by a bare hash. Only completed non-plain results
are inserted, and a cancelled or superseded request does not publish or cache.
The cache is main-actor isolated, so `CodeTokenizer` remains the only serial
owner of the JavaScript context; no new concurrency is introduced. A hit skips
the Prism call and publishes the completed tokens without a plain fallback pass.
The cache is memory-only and retains code text for the lifetime of the process,
so its size and retention must be confirmed on a device.

`HighlightedTextFragment.highlight()` resolves one `AttributeContainer` per token
type instead of per token, then styles token ranges inside a single
`AttributedString` built from the concatenated source. This removes one
intermediate attributed string and one append per token. Colors, fonts,
presentation intent and the `.keepNew` token merge policy are unchanged, and the
work stays synchronous on the main actor.

`NativeChatModel` enforces an 800-row in-memory window after `loadOlder` and
after a history snapshot that preserves earlier pages. Rows are dropped from the
oldest end; `olderOffset` still follows the server cursor for the oldest fetched
row, so a later page never re-reads the discarded range. The disk record keeps
its own retention cap and its full earlier pages. Anchored tools whose message
was dropped are deferred by `ChatTimeline` instead of being rendered as orphans,
and the tool array itself is still unbounded. Once the window is full, a further
older page is fetched and trimmed immediately, so backward paging effectively
stops at 800 mounted rows without moving the newest end; the fetch count, scroll
anchoring and the deferred tools need an iPhone check.

The two headless suites still compile the actual cache and publication helpers
(`tests/textualprimitives/run.sh`) and the render state machine
(`tests/renderpipeline/run.sh`). They do not execute SwiftUI Layout, JavaScriptCore
highlighting, attachment resolution or the paging window; those require a device.


## build46: transient Find occurrence geometry

`FindOccurrenceAttribute.swift` defines an integer-only, process-local attributed
text marker. The native UITextView bridge preserves it as an NSAttributedString
attribute, while code highlighting retains the source attributes before adding
syntax colors. The owning client scroll controller queries public UITextInput
range geometry on explicit Find commands. Selection ranges and pasteboard text
are not changed. This does not enable block measurement caching or alter scrolling.

## build51: paragraph coalescing for cross-paragraph selection

`BlockContent` used to render every block run as its own `NativeSelectableText`
UITextView, so a selection drag stopped at the paragraph boundary. Adjacent plain
paragraphs are now coalesced into one block (and therefore one text view).
Headings, lists, block quotes, code blocks, tables, math and paragraphs carrying
attachments keep their own block, and ranges are joined only when they are
contiguous in the source. One merged block is capped at 4,000 characters so a
streaming frame re-lays out a bounded section instead of the whole answer.

Coalescing removes the `BlockVStack` margin that used to separate paragraphs;
`textualNativeParagraphSpacing` re-supplies it as `NSParagraphStyle.paragraphSpacing`
on the run that ends a paragraph, while the final paragraph keeps Textual's own
block spacing. Hermes sets it to 0.65 em of the body font, scaled with Dynamic
Type, matching `ChatReadingParagraphStyle`.

`BlockCoalescer` is Foundation-only, so the grouping rule (adjacency, non-paragraph
blocks, contiguity, character limit) is covered by `tests/blockcoalescer`. Drag
handles, a selection that crosses a merged block, scroll-while-selecting and the
resulting row heights still need an iPhone check.

## build52: stable grouping, identity-based placeholder, async ratio cache

Coalescing is now opt-in per message (`textualBlockCoalescing`) and Hermes enables
it only for **finished** messages. Streaming messages keep one block per
paragraph, so the grouping can never change with the character count mid-stream.
The 4,000-character budget is gone: a finished message is one selectable section
regardless of length, and a pair no longer splits when its total crosses a
boundary (that rule was also asymmetric — a single 8,000-character paragraph was
never split).

`TextualSelectionActivity` reports whether any native text view in a message
holds a selection. Hermes keeps coalescing off until the selection ends, so the
structural rebuild cannot destroy an in-progress selection when a streaming
message finishes. The switch is per message, not global, and publishes only when
the aggregate state changes.

Placeholder hiding moved from a ±90 s timestamp window to the message identity:
the local optimistic id first, then the confirmed server id bound from the first
authoritative snapshot that contains the row. Timestamp-era records are purged on
load and no longer influence anything; a message whose id was never bound keeps
its text.

`ImageRatioStore` no longer touches the disk on the UI thread: snapshots read
memory only, scope files are preloaded on a utility queue, and measurements are
coalesced into one background write. Removing a scope or clearing the cache bumps
a generation so a write queued by a late download callback is dropped.
# Hermes build53 integration correction

The client now latches paragraph coalescing with `ParagraphMergeState`. Selection
can defer the initial transition after streaming, but cannot turn coalescing off
for an already merged document. This fixes the integration predicate in build52;
the vendored rendering algorithms and upstream inventory are unchanged.
Pure state transitions are covered offline. Native range/gesture behavior remains
on `tests/manual-ios-1.17.0.md`; compilation is not iPhone selection acceptance.

## build216 accessibility audit follow-up

NativeSelectionTextView now uses a preferred body font and opts into UIKit
Dynamic Type, invalidating cached glyph measurements when the content size
category changes. Attributed heading/code/body fonts still resolve from
SwiftUI TextEnvironmentValues; selection, links and grouping are unchanged.
This is a narrow source-local patch, not a Textual dependency upgrade.
Simulator tests and physical-device typography remain distinct checks.
