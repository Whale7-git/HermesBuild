import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
}
var work = FindWorkState()
let first = work.begin()
for _ in 0..<100 { work.contentChanged() }
expect(work.startSearch(first), "latest snapshot enters worker after debounce")
for _ in 0..<1000 { work.contentChanged() }
expect(work.active && work.searching, "stream updates never cancel an executing worker")
expect(work.completeSearch(first), "coalesce a content burst into one next pass")
expect(work.active && !work.searching, "slot remains owned while next pass waits")
expect(work.startSearch(first), "follow-up uses same query ticket")
expect(!work.completeSearch(first) && !work.active, "settled search releases slot")

let stale = work.begin()
expect(work.startSearch(stale), "start stale worker")
work.cancel()
let replacement = work.begin()
expect(!work.completeSearch(stale) && work.active, "old completion cannot reset replacement")
expect(!work.startSearch(stale), "old debounce cannot launch a new worker")
expect(work.startSearch(replacement), "new query still runs")
expect(!work.completeSearch(replacement), "replacement finishes normally")

let emoji = "👨‍👩‍👧‍👦 cafe\u{301} CAFÉ"
let matches = ChatFindHighlight.utf16Ranges(of: "cafe", in: emoji)
expect(matches.count == 2, "same case/diacritic semantics for native ranges")
let raw = emoji as NSString
expect(matches.allSatisfy { raw.substring(with: $0).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) == "cafe" },
       "native UTF16 ranges select complete Unicode words")
expect(ChatFindHighlight.utf16Ranges(of: "x", in: String(repeating: "x ", count: 100)).count == 100,
       "highlights cover all search hits beyond old 64-hit cap")
print("FINDWORK_PASS waiting/computing coalescing, stale-task isolation and native Unicode ranges")

let engine = ChatFindWorker(countLimit: 2, byteLimit: 1024)
let documents = [ChatConversationSearch.Document(id: "old", text: "old needle"),
                 .init(id: "tail", text: "live")]
let before = await engine.find("needle", in: documents)
expect(before.map(\.rowID) == ["old"], "worker reads original snapshot")
let updated = await engine.find("needle", in: [documents[0], .init(id: "tail", text: "live needle"),
                                              .init(id: "new", text: "needle")])
expect(updated.map(\.rowID) == ["old", "tail", "new"], "cached documents update with live tail and new rows")
let detail = await engine.findDetailed("needle", in: [ChatConversationSearch.Document(
    id: "bounded", text: String(repeating: "needle ", count: 301))])
expect(detail.hits.count == 300 && detail.hasMoreMatches,
       "actor worker forwards actual truncation to UI")
let invalidDetail = await engine.findDetailed(String(repeating: "a", count: 513), in: documents)
expect(invalidDetail.queryTooLong && invalidDetail.hits.isEmpty,
       "actor worker distinguishes invalid query from zero results")
let count = await engine.cachedDocumentCount
expect(count <= 2, "rendered search cache obeys hard document budget")
let replacedHits = await engine.find("missing", in: [.init(id: "tail", text: "missing")])
expect(replacedHits.count == 1, "same-ID replacement never reuses stale text")
print("FINDWORK_PASS cached worker updates changed content and bounds retention")

let overflow = ChatFindWorker(countLimit: 128, byteLimit: 1024 * 1024)
let largeHistory = (0..<200).map { ChatConversationSearch.Document(id: "m-\($0)", text: "needle \($0)") }
_ = await overflow.find("needle", in: largeHistory)
let initialWork = await overflow.preparedDocumentCount
let second = await overflow.find("needle", in: largeHistory)
let repeatedWork = await overflow.preparedDocumentCount
expect(second.count == 200, "capacity does not truncate search results")
expect(repeatedWork - initialWork == 72, "sequential overflow must retain 128 reusable documents instead of LRU thrashing")
let retained = await overflow.cachedBytes
expect(retained <= 1024 * 1024, "search cache respects byte budget")
_ = await overflow.find("needle", in: [.init(id: "replacement", text: "needle changed")])
let shrunk = await overflow.cachedDocumentCount
expect(shrunk == 1, "removed history releases retained documents")

let all = ChatFindWorker()
_ = await all.find("needle", in: largeHistory)
let firstCount = await all.preparedDocumentCount
var growing = largeHistory
growing[199] = .init(id: "m-199", text: "needle tail grew")
_ = await all.find("needle", in: growing)
let afterGrowth = await all.preparedDocumentCount
expect(afterGrowth == firstCount + 1, "streaming tail re-prepares only the changed message")
print("FINDWORK_PASS 200-document overflow reuses stable subset; unchanged history avoids repeated preparation")
