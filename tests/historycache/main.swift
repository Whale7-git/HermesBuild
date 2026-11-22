import Foundation

@main struct HistoryCacheTests {
    static let manager = FileManager.default

    static func snapshot(session: String = "test", offset: Int = 0, texts: [String] = ["first", "second"], active: String? = nil) throws -> ChatSnapshot {
        var fields: [String: Any] = ["session_id": session, "read_only": false,
            "_messages_offset": offset, "model": "verified-model", "last_prompt_tokens": 20,
            "context_length": 100, "messages": texts.enumerated().map {
                ["id": "message-\(offset + $0.offset)", "role": $0.offset % 2 == 0 ? "user" : "assistant",
                 "content": $0.element, "timestamp": 1234] as [String: Any]
            }]
        if let active { fields["active_stream_id"] = active }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: fields))
    }

    static func root() throws -> URL {
        let url = manager.temporaryDirectory.appendingPathComponent("Hermes-history-tests-" + UUID().uuidString)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func jsonFiles(_ root: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }

    static func main() async throws {
        let directory = try root()
        defer { try? manager.removeItem(at: directory) }
        let namespace = UUID().uuidString
        let store = ChatHistoryStore(instanceID: namespace, sessionID: "test", accountScope: "account-a", rootDirectory: directory)
        var record = ChatHistoryRecord(snapshot: try snapshot(offset: 8, active: "old-running-stream"))
        record.messages[1].attachmentPaths = ["/api/file/raw?path=example.png"]
        record.tools = [ChatTool(id: "tool-1", name: "search", args: "query", result: "result", done: true,
                                 isError: false, afterMessageID: record.messages[0].id)]
        store.schedule(record)
        await store.flush()
        let restored = await store.load()
        precondition(restored?.messages == record.messages && restored?.tools == record.tools)
        precondition(restored?.olderOffset == 8 && restored?.usage?.contextFraction == 0.2)
        precondition(restored?.model == "verified-model")
        let file = try jsonFiles(directory).first!
        let json = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        precondition(!json.contains("old-running-stream") && !json.contains("activeStream") && !json.contains("lastEventID"))
        precondition(!file.lastPathComponent.contains(namespace), "names must stay opaque in directory listings")
        print("HISTORY_PASS display snapshot round trip excludes runtime stream state")

        // Write failures are classified without changing the cache contract:
        // the oversized single message is omitted whole, and the caller gets a
        // category it can put in runtime diagnostics without IDs or text.
        let reportRoot = try root()
        defer { try? manager.removeItem(at: reportRoot) }
        var reportPolicy = ChatHistoryStore.Policy()
        reportPolicy.maxEntryBytes = 100
        let reports = ReportBox()
        let reportStore = ChatHistoryStore(
            instanceID: namespace, sessionID: "report", accountScope: "account-report",
            rootDirectory: reportRoot, policy: reportPolicy,
            report: { reports.append($0) })
        reportStore.schedule(ChatHistoryRecord(
            snapshot: try snapshot(session: "report",
                                   texts: [String(repeating: "x", count: 1000)])))
        await reportStore.flush()
        precondition(reports.values == [ChatHistoryStore.WriteReport.failed(.sizeBudget)])
        let missingReportRecord = await reportStore.load()
        precondition(missingReportRecord == nil)
        print("HISTORY_PASS write failure category is reported once without payload data")

        for other in [ChatHistoryStore(instanceID: namespace + "/other", sessionID: "test", accountScope: "account-a", rootDirectory: directory),
                      ChatHistoryStore(instanceID: namespace, sessionID: "other", accountScope: "account-a", rootDirectory: directory),
                      ChatHistoryStore(instanceID: namespace, sessionID: "test", accountScope: "account-b", rootDirectory: directory)] {
            let value = await other.load()
            precondition(value == nil, "instance, session and account must each isolate content")
        }
        let tupleA = ChatHistoryStore(instanceID: "a|b", sessionID: "c", accountScope: namespace, rootDirectory: directory)
        let tupleB = ChatHistoryStore(instanceID: "a", sessionID: "b|c", accountScope: namespace, rootDirectory: directory)
        let tupleRecord = ChatHistoryRecord(snapshot: try snapshot(session: "c"))
        tupleA.schedule(tupleRecord)
        await tupleA.flush()
        let isolated = await tupleB.load()
        precondition(isolated == nil)
        print("HISTORY_PASS exact instance/session/account tuple isolation")

        let wrongSession = ChatHistoryStore(instanceID: namespace, sessionID: "wrong", accountScope: "account-a", rootDirectory: directory)
        wrongSession.schedule(record)
        await wrongSession.flush()
        let refused = await wrongSession.load()
        precondition(refused == nil, "a miswired store must refuse another session's confirmed record")

        // Calls coalesce before encoding. Source positions keep optimistic and
        // live token rows out even if a caller passes an unsafe transcript.
        var unsafe = record
        unsafe.messages += [ChatMessage(id: "local-x", role: "user", content: "not confirmed", sourceIndex: 10),
                            ChatMessage(id: "streaming:x", role: "assistant", content: "partial", sourceIndex: 11),
                            ChatMessage(id: "no-source", role: "assistant", content: "partial")]
        unsafe.tools.append(ChatTool(id: "stream-tool:x", name: "busy", args: "", result: "", done: false, isError: false))
        for index in 0..<100 {
            unsafe.messages[0].content = "newest-\(index)"
            store.schedule(unsafe)
        }
        await store.flush()
        let coalesced = await store.load()
        precondition(coalesced?.messages.count == record.messages.count && coalesced?.tools.count == 1)
        precondition(coalesced?.messages.first?.content == "newest-99")
        print("HISTORY_PASS burst updates coalesce and unconfirmed rows are rejected")

        let capacityRoot = try root()
        defer { try? manager.removeItem(at: capacityRoot) }
        var smallPolicy = ChatHistoryStore.Policy()
        smallPolicy.maxMessages = 2
        let small = ChatHistoryStore(instanceID: namespace, sessionID: "test", accountScope: "small", rootDirectory: capacityRoot, policy: smallPolicy)
        small.schedule(ChatHistoryRecord(snapshot: try snapshot(offset: 10, texts: ["one", "two", "three", "four"])))
        await small.flush()
        let bounded = await small.load()
        precondition(bounded?.messages.map(\.content) == ["three", "four"] && bounded?.olderOffset == 12)
        // Oversized single messages are omitted whole, never truncated.
        var tinyPolicy = smallPolicy
        tinyPolicy.maxEntryBytes = 100
        let tiny = ChatHistoryStore(instanceID: namespace, sessionID: "large", accountScope: "small", rootDirectory: capacityRoot, policy: tinyPolicy)
        tiny.schedule(ChatHistoryRecord(snapshot: try snapshot(texts: [String(repeating: "x", count: 1000)])))
        await tiny.flush()
        let oversized = await tiny.load()
        precondition(oversized == nil)
        print("HISTORY_PASS capacity preserves complete newest messages and correct pagination boundary")

        let byteRoot = try root()
        defer { try? manager.removeItem(at: byteRoot) }
        var bytePolicy = ChatHistoryStore.Policy()
        bytePolicy.maxEntryBytes = 5000
        let byteStore = ChatHistoryStore(instanceID: namespace, sessionID: "bytes", accountScope: "byte-budget", rootDirectory: byteRoot, policy: bytePolicy)
        var longRows = ChatHistoryRecord(snapshot: try snapshot(session: "bytes", texts: (0..<20).map { "\($0)" + String(repeating: "x", count: 1000) }))
        longRows.tools = [ChatTool(id: "huge-tool", name: "search", args: "", result: String(repeating: "r", count: 20_000), done: true, isError: false)]
        byteStore.schedule(longRows)
        await byteStore.flush()
        let byteBounded = await byteStore.load()
        let byteStats = await ChatHistoryStore.statistics(rootDirectory: byteRoot)
        precondition(byteBounded?.messages.count == 2 && byteBounded?.messages.first?.sourceIndex == 18)
        precondition(byteBounded?.tools.map(\.id) == ["huge-tool"]
                     && byteBounded?.tools.first?.result.isEmpty == true
                     && byteBounded?.tools.first?.uncachedResultBytes == 20_000
                     && byteStats.bytes <= Int64(bytePolicy.maxEntryBytes),
                     "oversized result must retain tool identity and explicit missing bytes")
        print("HISTORY_PASS pre-encode byte budget retains tool identity without the giant payload")

        // A-07: multiple results over 4 MiB must not silently vanish on restart.
        let bigRoot = try root()
        defer { try? manager.removeItem(at: bigRoot) }
        let bigStore = ChatHistoryStore(instanceID: namespace, sessionID: "large-tools",
            accountScope: "large-account", rootDirectory: bigRoot)
        var huge = ChatHistoryRecord(snapshot: try snapshot(session: "large-tools"))
        huge.tools = (0..<3).map { index in
            ChatTool(id: "big-\(index)", name: "read_file", args: "path-\(index)",
                     result: String(repeating: "z", count: 5 * 1024 * 1024),
                     done: true, isError: false, afterMessageID: huge.messages[0].id)
        }
        bigStore.schedule(huge)
        await bigStore.flush()
        let bigCold = await bigStore.load()
        let bigStats = await ChatHistoryStore.statistics(rootDirectory: bigRoot)
        precondition(bigCold?.tools.map(\.id) == ["big-0", "big-1", "big-2"]
                     && bigCold?.tools.allSatisfy({ $0.result.isEmpty
                         && $0.uncachedResultBytes == 5 * 1024 * 1024 }) == true
                     && bigCold?.uncachedToolCount == 0
                     && bigStats.bytes <= 4 * 1024 * 1024,
                     "three 5MiB tool results must restore identities and missing-payload state under budget")
        let otherAccount = ChatHistoryStore(instanceID: namespace, sessionID: "large-tools",
            accountScope: "other-account", rootDirectory: bigRoot)
        let isolatedLarge = await otherAccount.load()
        precondition(isolatedLarge == nil,
                     "omission metadata must not escape instance/session/account scope")
        await bigStore.remove()
        let missingAfterRemoval = await bigStore.load()
        precondition(missingAfterRemoval == nil,
                     "cleared cache cannot retain references to missing results")
        print("HISTORY_PASS >4MiB results, cold boot, isolation and deletion")

        // If even an identity placeholder cannot fit, preserve a scoped count
        // rather than making offline history appear authoritative and complete.
        var markerPolicy = ChatHistoryStore.Policy()
        markerPolicy.maxEntryBytes = 1_500
        let marker = ChatHistoryStore(instanceID: namespace, sessionID: "marker",
            accountScope: "marker", rootDirectory: bigRoot, policy: markerPolicy)
        var markerRecord = ChatHistoryRecord(snapshot: try snapshot(session: "marker"))
        markerRecord.tools = [ChatTool(id: "not-cacheable", name: "search", args: "",
            result: String(repeating: "k", count: 5000), done: true, isError: false)]
        marker.schedule(markerRecord)
        await marker.flush()
        let markerCold = await marker.load()
        precondition(markerCold?.tools.isEmpty == true && markerCold?.uncachedToolCount == 1,
                     "identity overflow must remain observable as a missing count")
        print("HISTORY_PASS identity-overflow is disclosed instead of silently discarded")

        let corruptRoot = try root()
        defer { try? manager.removeItem(at: corruptRoot) }
        let corrupt = ChatHistoryStore(instanceID: namespace, sessionID: "test", accountScope: "corrupt", rootDirectory: corruptRoot)
        corrupt.schedule(record)
        await corrupt.flush()
        let corruptFile = try jsonFiles(corruptRoot).first!
        try Data("{incomplete".utf8).write(to: corruptFile)
        let broken = await corrupt.load()
        precondition(broken == nil && !manager.fileExists(atPath: corruptFile.path))
        corrupt.schedule(record)
        await corrupt.flush()
        var invalid = try JSONSerialization.jsonObject(with: Data(contentsOf: corruptFile)) as! [String: Any]
        invalid["version"] = 999
        try JSONSerialization.data(withJSONObject: invalid).write(to: corruptFile)
        let futureVersion = await corrupt.load()
        precondition(futureVersion == nil)
        var old = record
        old.savedAt = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        corrupt.schedule(old)
        await corrupt.flush()
        let expired = await corrupt.load()
        precondition(expired == nil)
        print("HISTORY_PASS interrupted JSON, unknown versions and expired records recover as cache misses")

        // A cache is display data, not a five-minute stream snapshot. It must
        // remain readable for the policy window and be retained by statistics
        // cleanup during the same interval.
        let ageRoot = try root()
        defer { try? manager.removeItem(at: ageRoot) }
        let ageStore = ChatHistoryStore(instanceID: namespace, sessionID: "age",
            accountScope: "age-policy", rootDirectory: ageRoot)
        let tenMinutesOld = ChatHistoryRecord(
            snapshot: try snapshot(session: "age"), savedAt: Date().addingTimeInterval(-10 * 60))
        ageStore.schedule(tenMinutesOld)
        await ageStore.flush()
        let ageStats = await ChatHistoryStore.statistics(rootDirectory: ageRoot)
        let retainedAfterCleanup = await ageStore.load()
        precondition(ageStats.entries == 1,
                     "statistics cleanup must honor policy.maxAge rather than delete after five minutes")
        precondition(retainedAfterCleanup?.messages == tenMinutesOld.messages,
                     "a ten-minute-old cache remains readable under the default policy")
        print("HISTORY_PASS read and cleanup both honor policy.maxAge")

        let totalRoot = try root()
        defer { try? manager.removeItem(at: totalRoot) }
        let first = ChatHistoryStore(instanceID: namespace, sessionID: "one", accountScope: "capacity", rootDirectory: totalRoot)
        var oldest = ChatHistoryRecord(snapshot: try snapshot(texts: [String(repeating: "a", count: 200)]))
        oldest.savedAt = Date().addingTimeInterval(-5)
        oldest = ChatHistoryRecord(snapshot: try snapshot(session: "one", texts: [String(repeating: "a", count: 200)]), savedAt: oldest.savedAt)
        first.schedule(oldest)
        await first.flush()
        let initialStats = await ChatHistoryStore.statistics(rootDirectory: totalRoot)
        var totalPolicy = ChatHistoryStore.Policy()
        totalPolicy.maxTotalBytes = initialStats.bytes + 64
        let second = ChatHistoryStore(instanceID: namespace, sessionID: "two", accountScope: "capacity", rootDirectory: totalRoot, policy: totalPolicy)
        second.schedule(ChatHistoryRecord(snapshot: try snapshot(session: "two", texts: [String(repeating: "b", count: 200)])))
        await second.flush()
        let limited = await ChatHistoryStore.statistics(rootDirectory: totalRoot)
        let evicted = await first.load()
        let newest = await second.load()
        precondition(limited.entries == 1 && limited.bytes <= totalPolicy.maxTotalBytes && evicted == nil && newest != nil)
        print("HISTORY_PASS global byte cap evicts oldest sessions across files")

        store.schedule(record)
        await ChatHistoryStore.remove(instanceID: namespace, accountScope: "account-a", rootDirectory: directory)
        store.schedule(record)
        await store.flush()
        let retiredAccount = await store.load()
        precondition(retiredAccount == nil, "late old-account callbacks must not recreate files after signout")
        let sessionStore = ChatHistoryStore(instanceID: namespace, sessionID: "delete", accountScope: "account-b", rootDirectory: directory)
        let deleteRecord = ChatHistoryRecord(snapshot: try snapshot(session: "delete"))
        sessionStore.schedule(deleteRecord)
        await sessionStore.remove()
        sessionStore.schedule(deleteRecord)
        await sessionStore.flush()
        let deletedSession = await sessionStore.load()
        precondition(deletedSession == nil)
        // A newly reopened session with the very same ID must recover its
        // cache; the old session object may never write after retirement.
        let reopened = ChatHistoryStore(instanceID: namespace, sessionID: "delete",
            accountScope: "account-b", rootDirectory: directory)
        reopened.schedule(deleteRecord)
        await reopened.flush()
        let firstReopen = await reopened.load()
        precondition(firstReopen != nil,
                     "a newly created store can cache a reused session ID")
        sessionStore.schedule(deleteRecord)
        await sessionStore.flush()
        let survivesLateWrites = await reopened.load()
        precondition(survivesLateWrites != nil,
                     "late writes from the retired controller cannot erase the new cache")
        // A second delete invalidates the reopened owner and grants only the
        // store constructed after the second completed deletion.
        await reopened.remove()
        reopened.schedule(deleteRecord)
        await reopened.flush()
        let third = ChatHistoryStore(instanceID: namespace, sessionID: "delete",
            accountScope: "account-b", rootDirectory: directory)
        third.schedule(deleteRecord)
        await third.flush()
        let freshThird = await third.load()
        let retiredSecond = await reopened.load()
        precondition(freshThird != nil && retiredSecond == nil,
                     "session generations reject obsolete writers across repeated deletes")
        tupleA.schedule(tupleRecord)
        await ChatHistoryStore.clearAll(rootDirectory: directory)
        tupleA.schedule(tupleRecord)
        await tupleA.flush()
        let cleared = await ChatHistoryStore.statistics(rootDirectory: directory)
        precondition(cleared.entries == 0)
        let newGeneration = ChatHistoryStore(instanceID: "a|b", sessionID: "c", accountScope: namespace, rootDirectory: directory)
        newGeneration.schedule(tupleRecord)
        await newGeneration.flush()
        let fresh = await newGeneration.load()
        precondition(fresh != nil, "reopened pages use a new generation after clear-all")
        print("HISTORY_PASS namespace, session and all-cache retirement block delayed resurrection")
        // build159: cleanup must distinguish a directory read failure from
        // an empty cache, and return verifiable per-file counts.
        let blockedRoot = directory.appendingPathComponent("not-a-directory")
        precondition(manager.createFile(atPath: blockedRoot.path,
                                        contents: Data("file".utf8)))
        let globalFailure = await ChatHistoryStore.clearAll(rootDirectory: blockedRoot)
        precondition(!globalFailure.succeeded && globalFailure.failed == 1,
                     "an unreadable/non-directory root cannot be reported as cleaned")
        let scopedFailure = await ChatHistoryStore.remove(
            instanceID: "missing", accountScope: "missing", rootDirectory: blockedRoot)
        precondition(!scopedFailure.succeeded && scopedFailure.failed == 1,
                     "account cleanup must report failed directory enumeration")
        try manager.removeItem(at: blockedRoot)

        let positiveRoot = try root()
        defer { try? manager.removeItem(at: positiveRoot) }
        let positive = ChatHistoryStore(instanceID: namespace, sessionID: "cleanup-result",
            accountScope: "cleanup", rootDirectory: positiveRoot)
        positive.schedule(ChatHistoryRecord(snapshot: try snapshot(session: "cleanup-result")))
        await positive.flush()
        let positiveReport = await ChatHistoryStore.remove(
            instanceID: namespace, accountScope: "cleanup", rootDirectory: positiveRoot)
        precondition(positiveReport.succeeded && positiveReport.attempted == 1
                     && positiveReport.removed == 1,
                     "successful account cleanup reports exactly one deleted history file")
        let remainingPositive = try jsonFiles(positiveRoot)
        precondition(remainingPositive.isEmpty)
        print("HISTORY_CACHE_TESTS_PASS")
    }
}

private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ChatHistoryStore.WriteReport] = []
    var values: [ChatHistoryStore.WriteReport] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func append(_ value: ChatHistoryStore.WriteReport) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
