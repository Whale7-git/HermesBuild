import Foundation

struct MarkdownRenderRequest: Equatable {
    let source: String
    let finished: Bool
}

enum MarkdownRenderGate {
    static func allows(_ ready: MarkdownRenderRequest, latest: MarkdownRenderRequest?) -> Bool {
        latest == ready || (latest?.finished == false && !ready.finished
            && latest?.source.hasPrefix(ready.source) == true)
    }
}

/// Conservative source boundaries, not a second Markdown parser. Containers
/// remain together; document-wide constructs use the original full parser.
enum MarkdownBlockPlan {
    struct Plan: Equatable {
        let complete: [String]
        let tail: String
        let requiresWholeDocument: Bool
    }

    /// The complete blocks from a prior append-only render have passed the
    /// conservative boundary scanner and cannot change without a source
    /// replacement. Scan only the unfinished tail plus appended bytes.
    ///
    /// A late reference/HTML construct or a CR/CRLF newline must still force
    /// whole-document Markdown parsing; never freeze semantics speculatively.
    static func makeAppending(_ source: String, after previousSource: String,
                              plan previous: Plan?) -> Plan {
        guard let previous, !previous.requiresWholeDocument,
              !previous.complete.isEmpty,
              source.hasPrefix(previousSource) else {
            return make(source)
        }
        let prefixBytes = previous.complete.reduce(0) { $0 + $1.utf8.count }
        // The byte boundary was produced by make() at a terminated LF, not
        // by splitting arbitrary Unicode scalar sequences.
        let active = String(decoding: source.utf8.dropFirst(prefixBytes), as: UTF8.self)
        let extensionPlan = make(active)
        if extensionPlan.requiresWholeDocument {
            return Plan(complete: [], tail: source, requiresWholeDocument: true)
        }
        return Plan(complete: previous.complete + extensionPlan.complete,
                    tail: extensionPlan.tail, requiresWholeDocument: false)
    }

    static func make(_ source: String) -> Plan {
        let bytes = Array(source.utf8)
        // Preserve Foundation's CR/CRLF handling without guessing line offsets.
        if bytes.contains(13) { return Plan(complete: [], tail: source, requiresWholeDocument: true) }
        var parts: [String] = []
        var start = 0
        var cursor = 0
        var fence: (UInt8, Int)?
        var opaque = false
        var whole = false
        while cursor < bytes.count {
            let end = bytes[cursor...].firstIndex(of: 10) ?? bytes.count
            let terminated = end < bytes.count
            let next = terminated ? end + 1 : end
            // ArraySlice keeps the original byte buffer: allocating two new
            // arrays per line on each streaming update is unnecessary.
            let line = bytes[cursor..<end]
            let indent = line.prefix { $0 == 32 }.count
            let trimmed = line.dropFirst(indent)
            let blank = trimmed.allSatisfy { $0 == 9 || $0 == 32 }
            if let active = fence {
                let count = trimmed.prefix { $0 == active.0 }.count
                if indent <= 3, count >= active.1,
                   trimmed.dropFirst(count).allSatisfy({ $0 == 9 || $0 == 32 }) {
                    fence = nil
                    if !opaque && terminated {
                        parts.append(String(decoding: bytes[start..<next], as: UTF8.self))
                        start = next
                    }
                }
            } else {
                // Reference definitions, reference-style links/images and HTML
                // can change an earlier block. Never freeze that document.
                if trimmed.contains(91) || trimmed.contains(60) { whole = true }
                let marker = trimmed.first ?? 0
                let count = trimmed.prefix { $0 == marker }.count
                let info = trimmed.dropFirst(count)
                if indent <= 3, (marker == 96 || marker == 126), count >= 3,
                   marker != 96 || !info.contains(96) {
                    fence = (marker, count)
                } else if !blank {
                    let bullet = [UInt8(45), 43, 42].contains(marker)
                        && trimmed.dropFirst().first.map { $0 == 32 || $0 == 9 } == true
                    let digits = trimmed.prefix { (48...57).contains($0) }.count
                    let ordered = digits > 0 && digits <= 9 && trimmed.count > digits + 1
                        && [UInt8(46), 41].contains(trimmed[trimmed.startIndex + digits])
                        && [UInt8(32), 9].contains(trimmed[trimmed.startIndex + digits + 1])
                    if indent >= 4 || marker == 9 || marker == 62 || bullet || ordered || trimmed.contains(124) {
                        // A list/quote/table/indented-code tail stays intact,
                        // including all later lazy/indented continuation lines.
                        opaque = true
                    }
                } else if !opaque && terminated {
                    if bytes[start..<next].contains(where: { $0 != 10 && $0 != 32 && $0 != 9 }) {
                        parts.append(String(decoding: bytes[start..<next], as: UTF8.self))
                        start = next
                    }
                }
            }
            cursor = next
        }
        if whole { return Plan(complete: [], tail: source, requiresWholeDocument: true) }
        return Plan(complete: parts, tail: String(decoding: bytes[start...], as: UTF8.self), requiresWholeDocument: false)
    }
}
