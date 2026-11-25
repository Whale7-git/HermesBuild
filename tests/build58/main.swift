import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}

// MARK: - 1. 附件数量与体积是两种不同的错误

do {
    // 数量上限：用一个很小的 maxCount 触发，数据本身合法。
    var batch = AttachmentBatch(sessionID: "s", maxCount: 2, maxTotalBytes: 40 * 1024 * 1024)
    _ = try! batch.append(name: "a.txt", mime: "text/plain", data: Data([1]))
    _ = try! batch.append(name: "b.txt", mime: "text/plain", data: Data([2]))

    var countError: AttachmentError?
    do { _ = try batch.append(name: "c.txt", mime: "text/plain", data: Data([3])) }
    catch let error as AttachmentError { countError = error }
    check(countError == .tooMany, "exceeding the count limit reports tooMany, not tooLarge")
    check(countError?.errorDescription?.contains("大小") == false,
          "the count message must not talk about size")
    check(countError?.errorDescription?.contains("数量") == true,
          "the count message says it is about quantity")

    // 体积上限：数量没满，单条超过 20MB 封顶。
    var byteBatch = AttachmentBatch(sessionID: "s", maxCount: 8, maxTotalBytes: 40 * 1024 * 1024)
    var sizeError: AttachmentError?
    do {
        _ = try byteBatch.append(name: "big.bin", mime: "application/octet-stream",
                                 data: Data(repeating: 0, count: AttachmentMultipart.defaultMaxBytes + 1))
    } catch let error as AttachmentError { sizeError = error }
    check(sizeError == .tooLarge, "exceeding the per-file limit still reports tooLarge")
    check(sizeError?.errorDescription?.contains("大小") == true,
          "the size message talks about size")

    // 整批体积上限：单条合法但累计超限。
    var totalBatch = AttachmentBatch(sessionID: "s", maxCount: 8, maxTotalBytes: 300)
    _ = try! totalBatch.append(name: "a.bin", mime: "application/octet-stream",
                               data: Data(repeating: 0, count: 200))
    var totalError: AttachmentError?
    do {
        _ = try totalBatch.append(name: "b.bin", mime: "application/octet-stream",
                                  data: Data(repeating: 0, count: 200))
    } catch let error as AttachmentError { totalError = error }
    check(totalError == .tooLarge, "exceeding the batch byte budget reports tooLarge")

    // 两条错误必须能被区分开：调用方据此给不同提示。
    check(AttachmentError.tooMany != AttachmentError.tooLarge, "the two errors are distinct")

    // replace 走的也是体积判定，不该被数量影响（数量不变）。
    var replaceBatch = AttachmentBatch(sessionID: "s", maxCount: 2, maxTotalBytes: 40 * 1024 * 1024)
    let id = try! replaceBatch.append(name: "a.png", mime: "image/png", data: Data([1, 2, 3]))
    _ = try! replaceBatch.append(name: "b.png", mime: "image/png", data: Data([4]))
    try! replaceBatch.replace(id, name: "a2.png", mime: "image/png", data: Data([5, 6]))
    check(replaceBatch.items.count == 2, "replace never changes the item count")
}

// MARK: - 2. 会话级本地状态可以被清理

do {
    let suite = "hermes.sessionstate.test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let instance = "https://one/"
    let account = "acct-a"
    let session = "s-1"

    // 草稿
    let draft = ChatDraftStore(instanceID: instance, accountScope: account,
                               sessionID: session, defaults: defaults)
    draft.save("还没发出去的内容")
    check(draft.load() == "还没发出去的内容", "draft is stored")
    draft.remove()
    check(draft.load().isEmpty, "remove() clears the draft")
    check(ChatDraftStore(instanceID: instance, accountScope: account,
                         sessionID: session, defaults: defaults).load().isEmpty,
          "the draft removal is persisted")

    // 阅读位置
    let reading = ChatReadingPositionStore(instanceID: instance, accountScope: account,
                                           sessionID: session, defaults: defaults)
    reading.save(ChatReadingPosition(rowID: "m-1", offsetInRow: 12, following: false))
    check(reading.load() != nil, "reading position is stored")
    reading.remove()
    check(reading.load() == nil, "remove() clears the reading position")

    // 折叠状态
    let cellState = ChatCellStateStore(instanceID: instance, accountScope: account,
                                       sessionID: session, defaults: defaults)
    cellState.saveCollapsed(["m-1", "m-2"])
    check(!cellState.loadCollapsed().isEmpty, "collapsed rows are stored")
    cellState.remove()
    check(cellState.loadCollapsed().isEmpty, "remove() clears the collapsed rows")

    // 清理只影响自己的三元组：别的会话/账号不能被误删。
    let other = ChatDraftStore(instanceID: instance, accountScope: account,
                               sessionID: "s-2", defaults: defaults)
    let otherAccount = ChatDraftStore(instanceID: instance, accountScope: "acct-b",
                                      sessionID: session, defaults: defaults)
    other.save("另一个会话")
    otherAccount.save("另一个账号")
    draft.save("待清理")
    draft.remove()
    check(other.load() == "另一个会话", "removing one session keeps another session's draft")
    check(otherAccount.load() == "另一个账号", "removing one account keeps another account's draft")

    // 清空整个账号作用域：AppState 会调用三个 removeAll，这里照做。
    draft.save("d")
    other.save("o")
    reading.save(ChatReadingPosition(rowID: "m-9", offsetInRow: 1, following: true))
    cellState.saveCollapsed(["m-9"])
    ChatDraftStore.removeAll(instanceID: instance, accountScope: account, defaults: defaults)
    ChatReadingPositionStore.removeAll(instanceID: instance, accountScope: account, defaults: defaults)
    ChatCellStateStore.removeAll(instanceID: instance, accountScope: account, defaults: defaults)
    check(draft.load().isEmpty && other.load().isEmpty, "account-wide draft removal covers every session")
    check(reading.load() == nil, "account-wide removal clears the reading position")
    check(cellState.loadCollapsed().isEmpty, "account-wide removal clears collapsed rows")
    check(otherAccount.load() == "另一个账号", "account-wide removal leaves other accounts alone")
}

// MARK: - 3. 孤儿下载目录清理

do {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hermes-orphan-test-" + UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 一个「正在使用」的目录，一个「上次进程遗留」的目录。
    let live = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let notAUUID = root.appendingPathComponent("keep-me", isDirectory: true)
    for url in [live, orphan, notAUUID] {
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: url.appendingPathComponent("f.txt"))
    }

    let removed = AttachmentDownloadFiles.purge(root: root, keeping: [live.lastPathComponent])
    check(removed == 1, "only the orphan directory is removed (got \(removed))")
    check(FileManager.default.fileExists(atPath: live.path), "the live directory survives")
    check(!FileManager.default.fileExists(atPath: orphan.path), "the orphan directory is gone")
    check(FileManager.default.fileExists(atPath: notAUUID.path),
          "a directory that is not one of our UUID folders is left alone")

    // 符号链接不能被跟随删除。
    let target = root.appendingPathComponent("target.txt")
    try! Data("keep".utf8).write(to: target)
    let link = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    _ = AttachmentDownloadFiles.purge(root: root, keeping: [live.lastPathComponent])
    check(FileManager.default.fileExists(atPath: target.path),
          "purging never follows a symlink to its target")

    // 空 root 不该抛错。
    let emptyRoot = root.appendingPathComponent("missing", isDirectory: true)
    check(AttachmentDownloadFiles.purge(root: emptyRoot, keeping: []) == 0,
          "purging a missing root is a no-op")
}

// A settled POST must remove only its accepted ready references.
do {
    let suite = "hermes.attach.settle." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ChatDraftStore(instanceID: "a", accountScope: "b", sessionID: "s", defaults: defaults)
    let unrelated = ChatDraftStore(instanceID: "a", accountScope: "b", sessionID: "other", defaults: defaults)
    var batch = AttachmentBatch(sessionID: "s")
    let first = ChatAttachmentPayload(name: "accepted.txt", path: "/attachments/accepted.txt", mime: "text/plain", size: 1, isImage: false)
    let second = ChatAttachmentPayload(name: "other.txt", path: "/attachments/other.txt", mime: "text/plain", size: 1, isImage: false)
    batch.restoreReady([first, second])
    let pending = try! batch.append(name: "pending.txt", mime: "text/plain", data: Data([1, 2, 3]))
    let data = try! JSONEncoder().encode(batch.persistedValue)
    check(store.saveAttachmentDraft(data).succeeded, "store initial attachment batch")
    check(unrelated.saveAttachmentDraft(data).succeeded, "unrelated scope fixture")
    check(store.consumeSettledAttachmentPaths([first.path], sessionID: "wrong").failure == .corruptFile,
          "a foreign session cannot consume a draft")
    check(store.consumeSettledAttachmentPaths([first.path], sessionID: "s").succeeded,
          "accepted path is consumed")
    let persisted = try! JSONDecoder().decode(PersistedAttachmentBatch.self,
        from: store.loadAttachmentDraft().value!)
    check(persisted.items.count == 2 && persisted.items.contains(where: { $0.id == pending }),
          "pending bytes and unrelated uploaded reference survive")
    check(unrelated.loadAttachmentDraft().value == data, "other session is unchanged")
    check(store.consumeSettledAttachmentPaths([first.path], sessionID: "s").succeeded,
          "settlement is idempotent")
}

print("BUILD58_FIXES_PASS \(checks) assertions")
