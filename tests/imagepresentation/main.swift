import Foundation

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    print("  ok  " + message)
}

// MARK: - A. 纯图占位：只看消息身份

print("[placeholder]")

let placeholder = ChatAttachmentPlaceholder.systemText
let marked: Set<String> = ["srv-2", "local-1"]

check(ChatAttachmentPlaceholder.hidesBody(messageID: "srv-2", content: placeholder, role: "user",
                                          attachmentCount: 1, markedIDs: marked),
      "a marked message hides the placeholder body")
check(ChatAttachmentPlaceholder.hidesBody(messageID: "local-1", content: placeholder, role: "user",
                                          attachmentCount: 1, markedIDs: marked),
      "the local optimistic row hides it before the server row exists")

// 关键反例：正文相同、但没被标记的消息必须显示
check(ChatAttachmentPlaceholder.hidesBody(messageID: "srv-3", content: placeholder, role: "user",
                                          attachmentCount: 1, markedIDs: marked) == false,
      "a later message with the same text but its own id is never hidden")
check(ChatAttachmentPlaceholder.hidesBody(messageID: "srv-2", content: placeholder, role: "user",
                                          attachmentCount: 1, markedIDs: []) == false,
      "no record means no hiding, even for the identical text")
check(ChatAttachmentPlaceholder.hidesBody(messageID: "srv-2", content: placeholder + "请看一下",
                                          role: "user", attachmentCount: 1, markedIDs: marked) == false,
      "text that only starts with the placeholder is never hidden")
check(ChatAttachmentPlaceholder.hidesBody(messageID: "srv-2", content: placeholder, role: "user",
                                          attachmentCount: 0, markedIDs: marked) == false,
      "the same words without an attachment stay visible")
check(ChatAttachmentPlaceholder.hidesBody(messageID: "srv-2", content: placeholder, role: "assistant",
                                          attachmentCount: 1, markedIDs: marked) == false,
      "assistant rows are never treated as the user placeholder")
check(ChatAttachmentPlaceholder.hidesBody(messageID: "", content: placeholder, role: "user",
                                          attachmentCount: 1, markedIDs: marked) == false,
      "a message without an id cannot be matched")

// MARK: - 记录：本地 → 服务端 ID 绑定、作用域隔离、旧记录清理

print("[placeholder store]")

let suite = "hermes.placeholder.tests"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
// v1 存的是时间戳，升级后不得再参与判定。
defaults.set(Data("{}".utf8), forKey: "HermesChat.attachmentPlaceholder.v1.legacy")

let store = ChatAttachmentPlaceholderStore(defaults: defaults)
check(defaults.object(forKey: "HermesChat.attachmentPlaceholder.v1.legacy") == nil,
      "timestamp-era records are purged on load")

store.rememberLocal(scope: "i1|a1", sessionID: "s1", id: "local-1")
check(store.markedIDs(scope: "i1|a1", sessionID: "s1") == ["local-1"],
      "the local row is marked before confirmation")
store.bind(scope: "i1|a1", sessionID: "s1", localID: "local-1", confirmedID: "srv-9")
check(store.markedIDs(scope: "i1|a1", sessionID: "s1") == ["srv-9"],
      "binding replaces the local id with the confirmed one")
check(store.markedIDs(scope: "i2|a1", sessionID: "s1").isEmpty,
      "another instance never sees the mark")
check(store.markedIDs(scope: "i1|a2", sessionID: "s1").isEmpty,
      "another account of the same instance never sees the mark")
check(store.markedIDs(scope: "i1|a1", sessionID: "s2").isEmpty,
      "another session never sees the mark")

// 绑定必须持久化：重启后仍按同一 ID 判定
let reopened = ChatAttachmentPlaceholderStore(defaults: defaults)
check(reopened.markedIDs(scope: "i1|a1", sessionID: "s1") == ["srv-9"],
      "the confirmed id survives a new store instance")

reopened.removeScope("i1|a1")
check(reopened.markedIDs(scope: "i1|a1", sessionID: "s1").isEmpty,
      "removing a scope drops its marks")
reopened.bind(scope: "i1|a3", sessionID: "s9", localID: "", confirmedID: "srv-10")
reopened.clearAll()
check(reopened.markedIDs(scope: "i1|a3", sessionID: "s9").isEmpty,
      "clearing all drops every scope")
defaults.removePersistentDomain(forName: suite)

// 会话桶裁剪必须按写入时间，不能按 session ID 字典序。
// 反例：先写 a1/a2/a3，再写最新会话 z9；字典序会把 z9 裁掉，导致这条纯图消息
// 的文字重新出现（与 P0 同症状）。
print("[placeholder pruning]")

let pruneSuite = "hermes.placeholder.prune"
let pruneDefaults = UserDefaults(suiteName: pruneSuite)!
pruneDefaults.removePersistentDomain(forName: pruneSuite)
let pruned = ChatAttachmentPlaceholderStore(defaults: pruneDefaults,
                                            limits: .init(perSession: 80, perScope: 3))
for name in ["a1", "a2", "a3"] {
    pruned.bind(scope: "i|a", sessionID: name, localID: "", confirmedID: "srv-\(name)")
}
pruned.bind(scope: "i|a", sessionID: "z9", localID: "", confirmedID: "srv-z9")
check(pruned.markedIDs(scope: "i|a", sessionID: "z9") == ["srv-z9"],
      "the newest session survives pruning even when its id sorts last")
check(pruned.markedIDs(scope: "i|a", sessionID: "a1").isEmpty,
      "the oldest written session is the one dropped")
check(pruned.markedIDs(scope: "i|a", sessionID: "a2") == ["srv-a2"],
      "a newer session than a1 is kept")

// 重新写入一个已有会话应刷新它的时间，使它不再是最旧的那个。
pruned.bind(scope: "i|a", sessionID: "a2", localID: "", confirmedID: "srv-a2b")
pruned.bind(scope: "i|a", sessionID: "z8", localID: "", confirmedID: "srv-z8")
check(pruned.markedIDs(scope: "i|a", sessionID: "z8") == ["srv-z8"],
      "a freshly written session survives")
check(pruned.markedIDs(scope: "i|a", sessionID: "a2") == ["srv-a2", "srv-a2b"],
      "re-writing an existing session refreshes its recency")
check(pruned.markedIDs(scope: "i|a", sessionID: "a3").isEmpty,
      "the session that became oldest is dropped")
pruneDefaults.removePersistentDomain(forName: pruneSuite)

// MARK: - B. 图片布局：长图只看纵横比

print("[image layout]")

check(InlineImageLayout.isLong(ratio: 2.0), "h/w == 2 is long")
check(InlineImageLayout.isLong(ratio: 3.4), "a tall screenshot is long")
check(InlineImageLayout.isLong(ratio: 1.0) == false,
      "a square stays normal even though its natural height exceeds the cap on a wide row")
check(InlineImageLayout.isLong(ratio: 1.9) == false, "just below the threshold is not long")
check(InlineImageLayout.isLong(ratio: 0.5) == false, "a wide image is not long")
check(InlineImageLayout.isLong(ratio: nil) == false, "an unknown ratio is not long")
check(InlineImageLayout.isLong(ratio: .infinity) == false, "an invalid ratio is not long")
check(InlineImageLayout.isLong(ratio: -3) == false, "a negative ratio is not long")
check(InlineImageLayout.maxHeight(ratio: 3.0) == InlineImageLayout.longHeight,
      "long images use the folded height")
check(InlineImageLayout.maxHeight(ratio: 1.0) == InlineImageLayout.maxHeight,
      "normal images use the regular cap")
check(abs(InlineImageLayout.aspect(ratio: nil) - 4.0 / 3.0) < 0.0001,
      "an unknown ratio keeps the fixed 4:3 placeholder")
check(abs(InlineImageLayout.aspect(ratio: 2.0) - 0.5) < 0.0001,
      "the aspect modifier receives width/height")
check(InlineImageLayout.normalized(0) == nil && InlineImageLayout.normalized(100) == nil,
      "degenerate ratios are rejected")

// MARK: - B. 比例缓存：四层隔离、内存读、后台写、旧写入不复活

print("[ratio store]")

let ratioDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hermes-ratios-" + UUID().uuidString, isDirectory: true)
defer { try? FileManager.default.removeItem(at: ratioDirectory) }

let ratios = ImageRatioStore(directory: ratioDirectory, limits: .init(entries: 8, maxAge: 3_600))
ratios.remember(token: ratios.token(scope: "i1|a1"), sessionID: "s1", path: "/inbox/one.jpg", ratio: 3.5)
ratios.remember(token: ratios.token(scope: "i1|a1"), sessionID: "s1", path: "/inbox/two.jpg", ratio: 0.75)
ratios.remember(token: ratios.token(scope: "i1|a1"), sessionID: "s2", path: "/inbox/one.jpg", ratio: 1.25)

let firstSession = ratios.snapshot(scope: "i1|a1", sessionID: "s1")
check(firstSession.count == 2, "the snapshot holds only this session's images")
check(firstSession.ratio(for: "/inbox/one.jpg") == 3.5, "the path keeps its own ratio")
check(ratios.snapshot(scope: "i1|a1", sessionID: "s2").ratio(for: "/inbox/one.jpg") == 1.25,
      "the same path in another session is a different record")
check(ratios.snapshot(scope: "i2|a1", sessionID: "s1").count == 0,
      "another instance never sees the ratios")
check(ratios.snapshot(scope: "i1|a2", sessionID: "s1").count == 0,
      "another account of the same instance never sees the ratios")

// 写盘：排队中的写入由显式 flush 收口，新实例同步预载后可见
ratios.flushPendingWrites()
let reopenedRatios = ImageRatioStore(directory: ratioDirectory, limits: .init(entries: 8, maxAge: 3_600))
reopenedRatios.preloadSynchronously(scope: "i1|a1")
check(reopenedRatios.snapshot(scope: "i1|a1", sessionID: "s1").ratio(for: "/inbox/one.jpg") == 3.5,
      "the snapshot survives a new store instance")

// 删除排队中的写入：清空后旧回调不能再复活记录
ratios.remember(token: ratios.token(scope: "i1|a1"), sessionID: "s1", path: "/inbox/three.jpg", ratio: 2.0)
ratios.remove(scope: "i1|a1")
ratios.flushPendingWrites()
check(ratios.snapshot(scope: "i1|a1", sessionID: "s1").count == 0,
      "removing a scope drops the in-memory ratios")
let afterRemoval = ImageRatioStore(directory: ratioDirectory, limits: .init(entries: 8, maxAge: 3_600))
afterRemoval.preloadSynchronously(scope: "i1|a1")
check(afterRemoval.snapshot(scope: "i1|a1", sessionID: "s1").count == 0,
      "a write queued before removal never reaches the disk")

// 不可信比例不写入
ratios.remember(token: ratios.token(scope: "i1|a1"), sessionID: "s3", path: "/inbox/bad.jpg", ratio: 0)
check(ratios.snapshot(scope: "i1|a1", sessionID: "s3").count == 0, "a zero ratio is not cached")

// 全清：内存与目录都不留
ratios.remember(token: ratios.token(scope: "i1|a3"), sessionID: "s9", path: "/inbox/x.jpg", ratio: 1.1)
ratios.clearAll()
ratios.flushPendingWrites()
check(ratios.snapshot(scope: "i1|a3", sessionID: "s9").count == 0, "clearing all drops every scope")
check(!FileManager.default.fileExists(atPath: ratioDirectory.path),
      "clearing all removes the cache directory")

// MARK: - C. 工具摘要

print("[tool summary]")

func tool(_ name: String, done: Bool = true, isError: Bool = false) -> ChatToolSummary.Item {
    ChatToolSummary.Item(name: name, done: done, isError: isError)
}

check(ChatToolSummary.summary([tool("terminal"), tool("terminal")]) == "terminal ×2",
      "two tools with the same name collapse into one counted group")
check(ChatToolSummary.summary([tool("terminal"), tool("read_file")]) == "terminal · read_file",
      "distinct names stay separate")
check(ChatToolSummary.summary([tool("a"), tool("b"), tool("c"), tool("d")]) == "c · d +2",
      "only the latest two groups are shown, the rest become +N")
check(ChatToolSummary.summary([tool("terminal"), tool("terminal"), tool("read_file"), tool("write_file")])
        == "read_file · write_file +2",
      "a repeated older group is folded into +N")
check(ChatToolSummary.summary([]) == "", "an empty group has no summary")
check(ChatToolSummary.summary([tool("terminal"), tool("read_file", done: false)], allowsRunning: true)
        == "read_file",
      "a running group shows the active tool")

check(ChatToolSummary.title([tool("a"), tool("b"), tool("c")]) == "已完成 3 项操作",
      "settled groups use plain language")
check(ChatToolSummary.title([tool("a"), tool("b"), tool("c", isError: true)]) == "3 项 · 1 个失败",
      "failures are counted, not folded into success")
check(ChatToolSummary.title([tool("a"), tool("b"), tool("c", done: false)]) == "3 项 · 状态待核对",
      "unfinished tools are reported as unverified")
check(ChatToolSummary.title([tool("a"), tool("b"), tool("c", done: false)], allowsRunning: true)
        == "工具进度 2/3",
      "a live group reports progress")
check(ChatToolSummary.title([tool("a", isError: true), tool("b", isError: true)]) == "2 项 · 2 个失败",
      "several failures count individually")
check(ChatToolSummary.title([]) == "", "an empty group has no title")

check(ChatToolSummary.statusLine([]) == "", "no fictitious status for empty tool groups")
check(ChatToolSummary.statusLine([tool("one"), tool("two")]) == "",
      "all-success groups remain a single compact line")
check(ChatToolSummary.statusLine([tool("a"), tool("b", done: false), tool("c", isError: true)])
      == "1 成功 · 1 失败 · 1 待核对",
      "mixed settled/error/unknown tools have honest independent counts")
check(ChatToolSummary.statusLine([tool("a", done: false), tool("b", isError: true)],
                                 allowsRunning: true) == "1 失败 · 1 执行中",
      "only live progress may label unsettled tools as executing")
check(ChatToolSummary.statusLine([tool("a", done: false), tool("b", isError: true)],
                                 allowsRunning: false) == "1 失败 · 1 待核对",
      "disconnected or historical tools are not mislabeled live")
check(ChatToolSummary.statusLine([tool("error", done: false, isError: true)]) == "1 失败",
      "error overrides an unset done bit")
print("IMAGE_PRESENTATION_PASS placeholder/layout/isolation/summary; SwiftUI hit areas, VoiceOver and real row heights require device")
