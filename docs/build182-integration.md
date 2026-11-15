# Hermes 2.33.0 / build182 — integrated iOS fixes

Baseline: `main` build181, integration from four independent source branches.

## First-turn and native Session safety
- The home draft is committed to the destination Session's protected store
  before route transition. A one-use, identity-scoped claim permits at most
  one POST through the established native sender. Any uncertain outcome stays
  locked until user-initiated verification; never automatically replay POST.
- A newly created Session is immediately added to the on-device drawer.
- Home Plus stages text without POST and opens the destination conversation's
  native photo/file chooser. Session and attachment intent are consumed once.
- First automatic user turn uses the same reading anchor as normal sends.
- "New chat" always opens an unsent local draft workspace.

## UI
- Home input no longer has a third expanding Spacer below it; it remains at
  the bottom safe area. Simplified header and greeting.
- Quote is displayed as a removable, optionally expanded preview separate
  from UITextView. The original Hermes Markdown wire format is preserved in
  the protected draft and reconstructed on sending. Restoring a draft recovers
  the preview and typed reply.
- A model button no longer claims a large invisible tap region immediately
  next to Send; model list rows are compact, avoid repeated title/subtitle,
  and search sits above the list.

## Request-scoped reasoning effort
- Only the Gateway backend offers effort levels. Defaults omit
  `model_options`; explicit levels go into `POST /v1/runs`:
  `model_options: {reasoning_effort: "<level>"}`.
- The preference is local to instance, account, and session. It is not a
  durable server-wide setting and resets on confirmed model changes.
- The provider may reject a level. No automatic fallback or second POST.
  Gateway model listings do not expose a complete per-model valid-level set.
- WebUI and other unsupported backends cannot silently ignore an override.

## Acceptance boundary
CI verifies source scope, complete Linux Swift offline tests and one macOS
iPhoneOS candidate build. This does not replace physical device inspection
of keyboard, home layout, accessory popup, model menu or quotation UI.
