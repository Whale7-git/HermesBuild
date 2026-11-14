import Foundation

var checks = 0
@MainActor func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !value() { fatalError(label) }
}
let docs: [ChatConversationSearch.Document] = [
    .init(id: "m-a", text: "你好 Hermes 👨‍👩‍👧‍👦\nCafé CAFE hermes"),
    .init(id: "m-b", text: "边界测试你好你好"),
    .init(id: "m-c", text: "字面量 .* [abc] 不是正则")
]
expect(ChatConversationSearch.find("  ", in: docs).isEmpty, "whitespace query")
expect(ChatConversationSearch.find("HERMES", in: docs).map(\.rowID) == ["m-a", "m-a"], "case-insensitive ordered occurrences")
expect(ChatConversationSearch.find("cafe", in: docs).count == 2, "diacritic-insensitive")
expect(ChatConversationSearch.find("你好", in: docs).count == 3, "Chinese occurrences")
expect(ChatConversationSearch.find(".*", in: docs).count == 1, "literal search")
expect(ChatConversationSearch.find("missing", in: docs).isEmpty, "no match")
expect(ChatConversationSearch.find("你好", in: docs, limit: 2).count == 2, "bounded results")
expect(ChatConversationSearch.find("你好", in: docs, limit: 0).isEmpty, "zero budget")
expect(ChatConversationSearch.find(String(repeating: "x", count: 513), in: docs).isEmpty, "bounded query")
expect(ChatConversationSearch.find("Hermes", in: docs).first?.snippet.contains("👨‍👩‍👧‍👦") == true, "emoji preserved")
let long = [ChatConversationSearch.Document(id: "m-long", text: String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 20) + "needle" + String(repeating: "👨‍👩‍👧‍👦", count: 20))]
let hit = ChatConversationSearch.find("needle", in: long).first!
expect(hit.snippet.contains("needle") && !hit.snippet.contains("�"), "snippet Unicode bounds")
expect(hit.location == (String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 20) as NSString).length, "UTF16 position")
expect(ChatConversationSearch.find("你好", in: docs).map(\.id).count == Set(ChatConversationSearch.find("你好", in: docs).map(\.id)).count, "stable unique occurrence IDs")

let suite = "HermesReadingTests-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let a = ChatReadingPositionStore(instanceID: "one", accountScope: "alice", sessionID: "chat", defaults: defaults)
let b = ChatReadingPositionStore(instanceID: "one", accountScope: "bob", sessionID: "chat", defaults: defaults)
let c = ChatReadingPositionStore(instanceID: "two", accountScope: "alice", sessionID: "chat", defaults: defaults)
let d = ChatReadingPositionStore(instanceID: "one", accountScope: "alice", sessionID: "other", defaults: defaults)
expect(a.load() == nil, "empty store")
let point = ChatReadingPosition(rowID: "m-test", offsetInRow: 382.5, following: false)
a.save(point)
expect(a.load() == point, "roundtrip exact reading offset")
expect(b.load() == nil && c.load() == nil && d.load() == nil, "account instance session isolation")
a.save(.init(rowID: "m-bad", offsetInRow: .infinity, following: false))
expect(a.load() == point, "reject nonfinite offset")
a.save(.init(rowID: "m-bad", offsetInRow: -1, following: false))
expect(a.load() == point, "reject negative offset")
a.save(.init(rowID: "", offsetInRow: 0, following: false))
expect(a.load() == point, "reject empty anchor")
a.save(.init(rowID: "m-last", offsetInRow: 0, following: true))
expect(a.load()?.following == true, "returning to latest replaces old anchor")
let joinedA = ChatReadingPositionStore(instanceID: "a:b", accountScope: "c", sessionID: "d", defaults: defaults)
let joinedB = ChatReadingPositionStore(instanceID: "a", accountScope: "b:c", sessionID: "d", defaults: defaults)
joinedA.save(point)
expect(joinedB.load() == nil, "tuple encoding avoids delimiter collision")
var readerClock = 100.0
let reader = ChatReaderPositionStore(
    instanceID: "one", accountScope: "alice", sessionID: "chat",
    defaults: defaults, clock: {
        defer { readerClock += 1 }
        return Date(timeIntervalSince1970: readerClock)
    })
let otherReader = ChatReaderPositionStore(
    instanceID: "one", accountScope: "bob", sessionID: "chat", defaults: defaults)
let readerText = "# Answer\n\nStable response"
let readerPosition = ChatReaderPosition(
    offset: 640.5, progress: 0.5, viewportWidth: 390,
    contentFingerprint: ChatReadingFingerprint.fnv1a(readerText),
    updatedAt: 101)
expect(reader.position(messageID: "m-1", content: readerText) == nil,
       "empty reader position")
reader.save(offset: 640.5, maximumOffset: 1281, viewportWidth: 390,
            messageID: "m-1", content: readerText)
let savedReader = reader.position(messageID: "m-1", content: readerText)
expect(savedReader?.offset == 640.5 && savedReader?.progress == 0.5,
       "reader offset and normalized progress round trip")
reader.save(offset: 900, maximumOffset: 400, viewportWidth: 390,
            messageID: "m-clamped", content: readerText)
expect(reader.position(messageID: "m-clamped", content: readerText)?.offset == 400,
       "reader offset is clamped to the measured maximum")
expect(reader.position(messageID: "m-1", content: readerText + " changed") == nil,
       "changed reply invalidates the old reader position")
expect(reader.position(messageID: "m-2", content: readerText) == nil,
       "reader positions are isolated per message")
expect(otherReader.position(messageID: "m-1", content: readerText) == nil,
       "reader positions are isolated per account")
reader.save(offset: .infinity, maximumOffset: 1281, viewportWidth: 390,
            messageID: "m-1", content: readerText)
expect(reader.position(messageID: "m-1", content: readerText)?.offset == 640.5,
       "reject nonfinite reader offset")
let sameLayoutTarget = ChatReaderPositionRestorePolicy.targetOffset(
    readerPosition, maximumOffset: 1600, viewportWidth: 390, content: readerText)
expect(sameLayoutTarget == 640.5, "same width restores exact offset")
let reflowTarget = ChatReaderPositionRestorePolicy.targetOffset(
    readerPosition, maximumOffset: 2000, viewportWidth: 430, content: readerText)
expect(reflowTarget == 1000, "width change restores normalized progress")
expect(ChatReaderPositionRestorePolicy.targetOffset(
    readerPosition, maximumOffset: 2000, viewportWidth: 390,
    content: readerText + " changed") == nil,
    "fingerprint mismatch never restores")
expect(ChatReaderPositionRestorePolicy.targetOffset(
    readerPosition, maximumOffset: 200, viewportWidth: 390,
    content: readerText) == 200,
    "a shortened reply clamps a saved exact offset")
let legacyReader = try JSONEncoder().encode([
    "m-legacy": ["offset": 120.0, "updatedAt": 10.0]
])
let legacyKey = "HermesNative.reader.v1."
    + (try JSONEncoder().encode(["one", "alice", "chat"])).base64EncodedString()
defaults.set(legacyReader, forKey: legacyKey)
expect(reader.position(messageID: "m-legacy", content: readerText) == nil,
       "build126 offset-only cache decodes but is not trusted without a fingerprint")
for index in 0..<70 {
    reader.save(offset: Double(index), maximumOffset: 100, viewportWidth: 390,
                messageID: "reader-\(index)", content: readerText)
}
reader.save(offset: 777, maximumOffset: 1281, viewportWidth: 390,
            messageID: "m-1", content: readerText)
expect(reader.position(messageID: "m-1", content: readerText)?.offset == 777,
       "recent reader position survives pruning")
for index in 0..<24 {
    reader.save(offset: Double(index), maximumOffset: 100, viewportWidth: 390,
                messageID: String(repeating: "long-\(index)-", count: 100),
                content: readerText)
}
reader.save(offset: 777, maximumOffset: 1281, viewportWidth: 390,
            messageID: "m-1", content: readerText)
expect(reader.position(messageID: "m-1", content: readerText)?.offset == 777,
       "byte-bounded pruning retains the most recent reader position")
ChatReaderPositionStore.removeAll(instanceID: "one", accountScope: "alice",
                                  defaults: defaults)
expect(reader.position(messageID: "m-1", content: readerText) == nil,
       "account-wide reader cleanup")
expect(otherReader.position(messageID: "m-1", content: readerText) == nil,
       "other account remains independent")
let frames = ChatViewportLayout.frames(for: [.init(id: "first", height: 200), .init(id: "target", height: 1000)])
expect(ChatViewportLayout.navigationOffset(in: frames, id: "target", offsetInRow: 600, viewport: 700, measurementPending: true) == nil, "wait for measured content below target")
expect(ChatViewportLayout.navigationOffset(in: frames, id: "target", offsetInRow: 600, viewport: 700, measurementPending: false) == 500, "final clamp near conversation end")
expect(ChatViewportLayout.navigationOffset(in: frames, id: "target", offsetInRow: 100, viewport: 700, measurementPending: true) == 300, "restore exact line when tail fills viewport")
expect(ChatViewportLayout.navigationOffset(in: frames, id: "missing", offsetInRow: 0, viewport: 700, measurementPending: false) == nil, "missing anchor")
expect(ChatViewportLayout.navigationOffset(in: frames, id: "target", offsetInRow: .nan, viewport: 700, measurementPending: false) == nil, "reject invalid geometry")
expect(ChatViewportLayout.navigationOffset(in: frames, id: "target", offsetInRow: 0, viewport: 0, measurementPending: false) == nil, "wait for actual viewport")
print("CONVERSATION_READING_PASS \(checks) assertions")
