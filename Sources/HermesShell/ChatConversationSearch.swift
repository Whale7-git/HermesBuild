import Foundation
#if canImport(Darwin)
import Textual
#endif

enum ChatConversationSearch {
    struct Document: Sendable {
        let id: String
        let text: String
        var markdown = false
    }
    struct Hit: Identifiable, Equatable, Sendable {
        let rowID: String
        let location: Int
        let snippet: String
        var id: String { "\(rowID):\(location)" }
    }
    /// Literal, case/diacritic-insensitive search of loaded message bodies only.
    /// UTF-16 offsets are confined to NSString and snippets never split graphemes.
    static func find(_ query: String, in documents: [Document], limit: Int = 300) -> [Hit] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf16.count <= 512, limit > 0 else { return [] }
        var hits: [Hit] = []
        for document in documents {
            if Task.isCancelled { break }
            let source = searchableText(document) as NSString
            var start = 0
            while start < source.length && hits.count < limit {
                if Task.isCancelled { return [] }
                let range = source.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: start, length: source.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                let lower = max(0, range.location - 32)
                let upper = min(source.length, NSMaxRange(range) + 64)
                let excerpt = source.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
                let text = source.substring(with: excerpt).replacingOccurrences(of: "\n", with: " ")
                hits.append(Hit(rowID: document.id, location: range.location,
                    snippet: (lower > 0 ? "…" : "") + text + (upper < source.length ? "…" : "")))
                start = NSMaxRange(range)
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Use the same Foundation parser as the visible Markdown document. Source
    /// syntax and link destinations must not shift visible occurrence ordinals.
    static func searchableText(_ document: Document) -> String {
        #if canImport(Darwin)
        if document.markdown,
           let parsed = try? AttributedString(markdown: document.text, including: \.textual,
                                             options: .init(), baseURL: nil) {
            return String(parsed.characters)
        }
        #endif
        return document.text
    }
}

/// Waiting and computing both own the single search slot. Content arriving
/// during a computation schedules one later pass; it never cancels that pass.
/// Tickets also prevent a cancelled old task from resetting its successor.
struct FindWorkState {
    private(set) var ticket: UInt64 = 0
    private(set) var active = false
    private(set) var searching = false
    private var dirty = false

    mutating func begin() -> UInt64 {
        ticket &+= 1; active = true; searching = false; dirty = false
        return ticket
    }
    mutating func cancel() {
        ticket &+= 1; active = false; searching = false; dirty = false
    }
    mutating func contentChanged() { if searching { dirty = true } }
    mutating func startSearch(_ token: UInt64) -> Bool {
        guard active, token == ticket else { return false }
        searching = true; dirty = false
        return true
    }
    mutating func completeSearch(_ token: UInt64) -> Bool {
        guard active, token == ticket else { return false }
        searching = false
        if dirty { dirty = false; return true }
        active = false
        return false
    }
}

/// Reuse unchanged rendered search text while the live tail grows. Parsing all
/// loaded Markdown again every 200ms would compete with the visible renderer.
actor ChatFindWorker {
    private struct Entry {
        let document: ChatConversationSearch.Document
        let plain: String
        let cost: Int
    }
    private var cache: [String: Entry] = [:]
    private var bytes = 0
    private let countLimit: Int
    private let byteLimit: Int
    var cachedDocumentCount: Int { cache.count }
    private(set) var preparedDocumentCount = 0
    var cachedBytes: Int { bytes }

    init(countLimit: Int = 800, byteLimit: Int = 8 * 1024 * 1024) {
        self.countLimit = max(0, countLimit)
        self.byteLimit = max(0, byteLimit)
    }

    func find(_ query: String, in documents: [ChatConversationSearch.Document]) -> [ChatConversationSearch.Hit] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf16.count <= 512 else { return [] }
        let currentIDs = Set(documents.map(\.id))
        for id in Array(cache.keys) where !currentIDs.contains(id) {
            if let old = cache.removeValue(forKey: id) { bytes -= old.cost }
        }
        var prepared: [ChatConversationSearch.Document] = []
        prepared.reserveCapacity(documents.count)
        for document in documents {
            if Task.isCancelled { return [] }
            let plain: String
            if let entry = cache[document.id], entry.document.text == document.text,
               entry.document.markdown == document.markdown {
                plain = entry.plain
            } else {
                preparedDocumentCount += 1
                plain = ChatConversationSearch.searchableText(document)
                if let old = cache.removeValue(forKey: document.id) { bytes -= old.cost }
                let cost = document.text.utf8.count + plain.utf8.count + 128
                // Stable admission is deliberate: sequentially scanning more
                // than capacity through an LRU evicts the ENTIRE previous pass.
                // Keep a reusable subset until those documents leave/change.
                if cache.count < countLimit, cost <= min(byteLimit, 256 * 1024), cost <= byteLimit - bytes {
                    cache[document.id] = Entry(document: document, plain: plain, cost: cost)
                    bytes += cost
                }
            }
            prepared.append(.init(id: document.id, text: plain))
        }
        return ChatConversationSearch.find(term, in: prepared)
    }
}

enum FindDebouncePolicy {
    enum Event { case queryChanged, contentChanged, cancelled }
    enum Action { case restart, keepWaiting, cancel }
    static func action(_ event: Event, running: Bool) -> Action {
        switch event {
        case .cancelled: return .cancel
        case .queryChanged: return .restart
        case .contentChanged: return running ? .keepWaiting : .restart
        }
    }
}
