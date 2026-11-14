import Foundation
import UIKit

/// Recycled message hosts may ask Textual to parse the same finished reply again.
/// Cache the document, rather than its view/layout, so font size and appearance
/// continue to resolve from the current environment.
@MainActor
enum ChatMarkdownParser {
    static var cacheGeneration: UInt64 { ChatMarkdownCache.shared.generation }
    static func clearCache() {
        ChatMarkdownCache.shared.removeAll()
    }

    static func cachedDocument(_ input: String) -> AttributedString? {
        ChatMarkdownCache.shared.cached(input)
    }

    static func remember(_ document: AttributedString, source: String) {
        ChatMarkdownCache.shared.remember(document, source: source)
    }
}

@MainActor
private final class ChatMarkdownCache: NSObject {
    static let shared = ChatMarkdownCache()

    private struct Entry {
        let document: AttributedString
        let cost: Int
        var lastAccess: UInt64
    }

    private let countLimit = 96
    private let costLimit = 8 * 1_024 * 1_024
    private let entryCostLimit = 256 * 1_024
    private var entries: [String: Entry] = [:]
    private var totalCost = 0
    private var clock: UInt64 = 0
    private(set) var generation: UInt64 = 0

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(removeAll),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    func cached(_ input: String) -> AttributedString? {
        if var entry = entries[input] {
            clock &+= 1
            entry.lastAccess = clock
            entries[input] = entry
            return entry.document
        }
        return nil
    }

    func remember(_ document: AttributedString, source input: String) {
        if let old = entries.removeValue(forKey: input) { totalCost -= old.cost }
        let sourceBytes = input.utf8.count
        guard sourceBytes <= entryCostLimit / 2 else { return }
        // This is an estimate, not a claim about Foundation's allocation sizes.
        // Include keys, output text and attribute runs, with a strict entry cap.
        let cost = sourceBytes * 2 + document.characters.count * 2 + document.runs.count * 256
        guard cost <= entryCostLimit else { return }
        while entries.count >= countLimit || totalCost + cost > costLimit {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
            totalCost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        clock &+= 1
        entries[input] = Entry(document: document, cost: cost, lastAccess: clock)
        totalCost += cost
    }

    @objc func removeAll() {
        generation &+= 1
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
    }
}
