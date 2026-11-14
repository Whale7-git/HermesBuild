import Foundation

/// Metadata only. The overview never scans files or downloads an attachment
/// merely to discover its type, size or membership.
enum AttachmentCatalog {
    struct Entry: Identifiable, Equatable {
        let id: String
        let role: String
        let timestamp: Double?
        let paths: [String]
        var rowID: String { "m-" + id }
    }

    static func entries(_ messages: [ChatMessage]) -> [Entry] {
        var seenMessages = Set<String>()
        return messages.reversed().compactMap { message in
            guard seenMessages.insert(message.id).inserted else { return nil }
            var seenPaths = Set<String>()
            let paths = message.attachmentPaths.filter { !$0.isEmpty && seenPaths.insert($0).inserted }
            guard !paths.isEmpty else { return nil }
            return Entry(id: message.id, role: message.role, timestamp: message.timestamp, paths: paths)
        }
    }
}

enum AttachmentGridPlan {
    static func visibleCount(_ count: Int) -> Int { min(4, max(0, count)) }
    static func overflow(_ count: Int) -> Int { max(0, count - 4) }
}
