import Foundation

@main struct DraftTests {
    static func main() throws {
        let suite = "HermesDraftTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let a = ChatDraftStore(instanceID:"https://one/",sessionID:"session",defaults:defaults)
        precondition(a.load().isEmpty)
        a.save("  draft\n草稿 🔐  ")
        precondition(ChatDraftStore(instanceID:"https://one/",sessionID:"session",defaults:defaults).load() == "  draft\n草稿 🔐  ")
        precondition(ChatDraftStore(instanceID:"https://two/",sessionID:"session",defaults:defaults).load().isEmpty)
        precondition(ChatDraftStore(instanceID:"https://one/",sessionID:"other",defaults:defaults).load().isEmpty)
        let collisionA = ChatDraftStore(instanceID:"a:b",sessionID:"c",defaults:defaults)
        let collisionB = ChatDraftStore(instanceID:"a",sessionID:"b:c",defaults:defaults)
        collisionA.save("value")
        precondition(collisionB.load().isEmpty)
        a.save("")
        precondition(a.load().isEmpty && collisionA.load() == "value")
        // ---- A06: v2 按 [instanceID, accountScope, sessionID] 隔离 ----
        let accountOne = ChatDraftStore(instanceID:"https://one/",accountScope:"acct-1",sessionID:"session",defaults:defaults)
        let accountTwo = ChatDraftStore(instanceID:"https://one/",accountScope:"acct-2",sessionID:"session",defaults:defaults)
        precondition(accountOne.load().isEmpty && accountTwo.load().isEmpty, "v2 starts empty per account")
        accountOne.save("账号一的草稿")
        precondition(accountOne.load() == "账号一的草稿", "v2 round-trip within one account")
        precondition(accountTwo.load().isEmpty, "同 instanceID+sessionID 不同 accountScope 互不可见")
        let queued = Data("complete queued payload".utf8)
        accountOne.saveQueued(queued)
        accountTwo.saveQueued(Data("another account".utf8))
        precondition(accountOne.loadQueued() == queued, "queued payload survives recreation")
        ChatDraftStore.removeAll(instanceID: "https://one/", accountScope: "acct-1", defaults: defaults)
        precondition(accountOne.loadQueued() == nil && accountOne.load().isEmpty,
                     "account cleanup removes both draft and queued payload")
        precondition(accountTwo.loadQueued() != nil, "queue cleanup never crosses accounts")
        accountTwo.remove()
        precondition(accountTwo.loadQueued() == nil, "deleting one session removes its queued payload")
        accountOne.save("账号一的草稿")
        let tupleCollisionA = ChatDraftStore(instanceID:"a:b",accountScope:"c",sessionID:"d",defaults:defaults)
        let tupleCollisionB = ChatDraftStore(instanceID:"a",accountScope:"b:c",sessionID:"d",defaults:defaults)
        tupleCollisionA.save("left")
        precondition(tupleCollisionB.load().isEmpty, "v2 tuple encoding resists delimiter collisions")
        // load 绝不回退读 v1：v1 里有旧草稿，v2 也必须读不到。
        let legacyOnly = ChatDraftStore(instanceID:"https://one/",sessionID:"session",defaults:defaults)
        legacyOnly.save("旧的 v1 草稿")
        let freshAccount = ChatDraftStore(instanceID:"https://one/",accountScope:"acct-3",sessionID:"session",defaults:defaults)
        precondition(freshAccount.load().isEmpty, "v2 load must never fall back to the v1 key")
        precondition(accountOne.load() == "账号一的草稿", "a stale v1 draft does not overwrite the account's own v2 draft")
        // save 非 nil legacyBaseURL 时删除对应 v1 键；不带 legacyBaseURL 不碰 v1。
        let legacyV1 = ChatDraftStore(instanceID:"https://legacy/",sessionID:"session",defaults:defaults)
        legacyV1.save("旧的 v1 草稿")
        let migrator = ChatDraftStore(instanceID:"https://legacy/",accountScope:"acct-9",sessionID:"session",legacyBaseURL:"https://legacy/",defaults:defaults)
        migrator.save("迁移后的草稿")
        precondition(migrator.load() == "迁移后的草稿", "v2 with legacyBaseURL round-trips")
        precondition(legacyV1.load().isEmpty, "saving a v2 draft with legacyBaseURL removes the matching v1 key")
        legacyV1.save("又写了 v1")
        let plainV2 = ChatDraftStore(instanceID:"https://legacy/",accountScope:"acct-9",sessionID:"session",defaults:defaults)
        plainV2.save("不带迁移的保存")
        precondition(plainV2.load() == "不带迁移的保存", "v2 without legacyBaseURL saves normally")
        precondition(legacyV1.load() == "又写了 v1", "v2 save without legacyBaseURL must not touch v1 keys")
        // ---- v1 两参数 init 行为完全不变 ----
        let v1 = ChatDraftStore(instanceID:"https://v1/",sessionID:"s",defaults:defaults)
        precondition(v1.load().isEmpty, "v1 starts empty")
        v1.save("v1 草稿")
        precondition(ChatDraftStore(instanceID:"https://v1/",sessionID:"s",defaults:defaults).load() == "v1 草稿", "v1 round-trip unchanged")
        precondition(ChatDraftStore(instanceID:"https://v1/",sessionID:"other",defaults:defaults).load().isEmpty, "v1 session isolation unchanged")
        precondition(ChatDraftStore(instanceID:"https://v1x/",sessionID:"s",defaults:defaults).load().isEmpty, "v1 instance isolation unchanged")
        v1.save("")
        precondition(v1.load().isEmpty && ChatDraftStore(instanceID:"https://v1/",sessionID:"other",defaults:defaults).load().isEmpty, "v1 clear unchanged")

        // build158: a single-instance cleanup must never remove another
        // host's unscoped v1 draft. The stable identity is [UUID, baseURL].
        let firstLegacy = ChatDraftStore(instanceID: "https://one/", sessionID: "session",
                                          defaults: defaults)
        let unrelatedLegacy = ChatDraftStore(instanceID: "https://elsewhere/", sessionID: "session",
                                              defaults: defaults)
        firstLegacy.save("A old draft")
        unrelatedLegacy.save("B old draft")
        let stableA = try JSONEncoder().encode([UUID().uuidString, "https://one/"])
            .base64EncodedString()
        let legacyCleanup = ChatDraftStore.removeAll(instanceID: stableA, accountScope: "acct-1",
                                                       defaults: defaults)
        precondition(legacyCleanup.succeeded && firstLegacy.load().isEmpty,
                     "target host legacy v1 records are removed")
        precondition(unrelatedLegacy.load() == "B old draft",
                     "deleting host A must preserve host B legacy v1 drafts")

        // ---- verified file store, scope isolation and one-way migration ----
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesDraftFiles-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LocalDataFileStore(instanceID: "instance", accountScope: "acct-1",
                                      sessionID: "session", rootDirectory: root)
        let fileDraft = ChatDraftStore(instanceID: "instance", accountScope: "acct-1",
                                       sessionID: "session", fileStore: file)
        precondition(fileDraft.save("第一版").succeeded)
        precondition(fileDraft.load() == "第一版")
        precondition(fileDraft.save("覆盖后").succeeded)
        precondition(fileDraft.load() == "覆盖后", "atomic replacement persists the newest draft")
        let queue = Data("verified queue".utf8)
        precondition(fileDraft.saveQueued(queue).succeeded)
        precondition(fileDraft.loadQueued() == queue)
        precondition(!fileDraft.saveQueued(Data()).succeeded, "empty queue never overwrites a valid value")
        precondition(fileDraft.loadQueued() == queue)

        let sameAccount = ChatDraftStore(instanceID: "instance", accountScope: "acct-1",
                                         sessionID: "other", fileStore: LocalDataFileStore(
                                            instanceID: "instance", accountScope: "acct-1",
                                            sessionID: "other", rootDirectory: root))
        let otherAccount = ChatDraftStore(instanceID: "instance", accountScope: "acct-2",
                                          sessionID: "session", fileStore: LocalDataFileStore(
                                            instanceID: "instance", accountScope: "acct-2",
                                            sessionID: "session", rootDirectory: root))
        precondition(sameAccount.load().isEmpty && otherAccount.load().isEmpty)
        sameAccount.save("另一个会话")
        otherAccount.save("另一个账号")
        precondition(fileDraft.load() == "覆盖后")
        precondition(sameAccount.load() == "另一个会话")
        precondition(otherAccount.load() == "另一个账号")

        let migratedKeyStore = ChatDraftStore(instanceID: "legacy-instance", accountScope: "acct-9",
                                              sessionID: "legacy-session", defaults: defaults)
        migratedKeyStore.save("待迁移草稿")
        migratedKeyStore.saveQueued(Data("待迁移队列".utf8))
        let migrationRoot = root.appendingPathComponent("migration", isDirectory: true)
        let migratedFile = LocalDataFileStore(instanceID: "legacy-instance", accountScope: "acct-9",
                                              sessionID: "legacy-session", rootDirectory: migrationRoot)
        let migrated = ChatDraftStore(instanceID: "legacy-instance", accountScope: "acct-9",
                                      sessionID: "legacy-session", defaults: defaults,
                                      fileStore: migratedFile)
        precondition(migrated.load() == "待迁移草稿")
        precondition(migrated.loadQueued() == Data("待迁移队列".utf8))
        precondition(migrated.load() == "待迁移草稿", "migration source is removed only after file read-back")

        let stats = LocalDataFileStore.statistics(instanceID: "instance", accountScope: "acct-1",
                                                  rootDirectory: root)
        precondition(stats.files >= 3 && stats.payloadBytes > 0 && stats.isHealthy)

        // A corrupt envelope is rejected and remains a visible failure; it is
        // never silently treated as an empty draft.
        let corruptRoot = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptStore = LocalDataFileStore(instanceID: "corrupt", accountScope: "acct",
                                              sessionID: "session", rootDirectory: corruptRoot)
        try Data("not-json".utf8).write(to: corruptStore.draftURL)
        let corrupt = corruptStore.loadDraft()
        precondition(corrupt.value == nil && corrupt.result.failure == .corruptFile)
        precondition(corruptStore.saveDraft("repaired").succeeded)
        precondition(corruptStore.loadDraft().value == "repaired",
                     "a verified replacement repairs a corrupt envelope")

        // An existing path that is a file cannot be enumerated as a directory.
        // Cleanup must report failure rather than claim it had nothing to do.
        let unreadableRoot = root.appendingPathComponent("not-directory")
        try Data("file".utf8).write(to: unreadableRoot)
        let cleanupFailure = LocalDataFileStore.removeAll(instanceID: "instance",
            accountScope: "acct-1", rootDirectory: unreadableRoot)
        precondition(cleanupFailure.failure == .diskWrite,
                     "unreadable cleanup root is reported as a failure")

        ChatDraftStore.removeAll(instanceID: "instance", accountScope: "acct-1",
                                 defaults: defaults, fileRootDirectory: root)
        precondition(fileDraft.load().isEmpty && fileDraft.loadQueued() == nil)
        precondition(otherAccount.load() == "另一个账号", "account cleanup never crosses namespaces")
        print("DRAFT_PASS round-trip, file verification, atomic overwrite, migration, corruption and scope isolation")
    }
}
