# Hermes 2.38.0 / build190 — bounded chat pagination lifecycle

Base: 2.37.3/build189 `main` commit `30eb2b7fdcce1529f5472c7e65b5bc435577e385`.

## Verified source gap

`NativeChatView+MessageList.loadOlderIfNeeded()` created an unowned `Task`: after a page was dismissed it could finish its 60ms timer and set the page loading state on a retired view. On page retirement the task had no cancellation/identity ticket. The underlying model already rejects late *successful* history replies by revision and Session ID; the cancellation/failure path also needed to avoid surfacing errors from an obsolete or suspended request.

## Fix

- Add a view-owned `paginationTask` and `ChatPaginationOwnership` single-active-request ticket. On page disappearance or active account/instance change, retire the ticket, cancel the task, end the pagination timing sample and reset the view loading flag. An old completion cannot retire a successor.
- Require `visible`, current app change token, scoped instance+account and native Session ID before committing completion.
- Preserve the 60ms UIKit layout settling interval, but distinguish its cancellation from legitimate completion.
- Model-side older-history GET cancellation and suspension no longer create a spurious error banner. Preserve the existing revision, history snapshot identity, cursor, page-budget, and running-Run protections.
- Add a pure ticket-lifecycle test in the existing scroll offline suite; add two controlled asynchronous history tests: cancelled fetch raising `CancellationError` and a late successful fetch after Session disconnect.

## Scope boundaries

No changes to SSE terminal semantics, Run/STOP/send queue, backend APIs, attachment protocol, native Markdown, rendering caches, keyboard sizing or existing scroll physics. Those already include defensive machinery. UI performance changes to those domains require measured device evidence rather than speculative refactors.

## Acceptance

Source/release-scope gate; full Swift offline regression; one macOS iPhoneOS candidate IPA compile and validation on the exact final PR head; promote the verified candidate after merge. Physical iPhone scrolling and keyboard acceptance has not been performed.
