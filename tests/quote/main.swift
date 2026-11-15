import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !value() { print("FAIL: \(label)"); exit(1) }
}

let assistant = ChatMessage(id: "a", role: "assistant", content: "第一段\n第二段")
check(ChatQuote.insertion(for: assistant) ==
      "> **引用 Hermes**\n> 第一段\n> 第二段\n\n",
      "assistant quote uses editable Markdown and leaves a reply caret")
let user = ChatMessage(id: "u", role: "user", content: "  你好  ")
check(ChatQuote.insertion(for: user) == "> **引用 你**\n> 你好\n\n",
      "user quote is labelled and surrounding whitespace is trimmed")
let blank = ChatMessage(id: "b", role: "assistant", content: "\u{200B}\n ")
check(ChatQuote.insertion(for: blank) == nil, "invisible content has no quote action")

let long = ChatMessage(id: "l", role: "assistant",
                       content: String(repeating: "长", count: ChatQuote.maximumCharacters + 200))
let clipped = ChatQuote.insertion(for: long)!
check(clipped.contains("（引用已截断）"), "long quote discloses truncation")
check(clipped.count < ChatQuote.maximumCharacters + 80, "long quote stays bounded")

let many = ChatMessage(id: "m", role: "assistant",
                       content: (0..<40).map { "第 \($0) 行" }.joined(separator: "\n"))
check(ChatQuote.insertion(for: many)!.contains("（引用已截断）"),
      "line cap discloses truncation")

check(ChatComposerInsertionPlan.append("> quote\n\n", to: "") == "> quote\n\n",
      "an empty draft receives the quote unchanged")
check(ChatComposerInsertionPlan.append("> quote\n\n", to: "reply") == "reply\n\n> quote\n\n",
      "a nonempty draft keeps its text and gains one blank line")
check(ChatComposerInsertionPlan.append("> quote\n\n", to: "reply\n") == "reply\n\n> quote\n\n",
      "an existing single newline is normalized to one blank line")
check(ChatComposerInsertionPlan.append("> quote\n\n", to: "reply\n\n") == "reply\n\n> quote\n\n",
      "existing blank spacing is not duplicated")
let ref = ChatQuote.reference(for: assistant)!
check(ref.author == "Hermes" && ref.preview == "第一段\n第二段",
      "reference UI has clean display text, not Markdown control characters")
let combined = ChatQuote.assemble(ref, reply: "这是我的回复")
let decoded = ChatQuote.splitDraft(combined)
check(decoded.reference == ref && decoded.reply == "这是我的回复",
      "display draft is separate but the original wire survives save/reopen")
check(ChatQuote.assemble(decoded.reference, reply: decoded.reply) == combined,
      "round-trip never mutates the backend message")
check(ChatQuote.splitDraft("普通正文").reference == nil
      && ChatQuote.splitDraft("普通正文").reply == "普通正文",
      "ordinary drafts are not incorrectly parsed as references")
let clippedParsed = ChatQuote.splitDraft(clipped)
check(clippedParsed.reference != nil && clippedParsed.reply.isEmpty
      && clippedParsed.reference!.wire == clipped,
      "truncated quote annotation stays with quote instead of leaking into typed reply")
check(ChatQuote.assemble(nil, reply: "原始回复") == "原始回复",
      "removing a quote sends only the user-authored reply")

check(ChatComposerInsertionPlan.append("", to: "reply") == "reply",
      "an empty insertion is a no-op")

print("CHAT_QUOTE_PASS \(checks) assertions")
