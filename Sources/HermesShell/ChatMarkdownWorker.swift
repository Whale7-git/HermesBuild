import Foundation
import Textual

struct MarkdownRenderMetrics: Sendable {
    var parsedBytes = 0
    var reusedBytes = 0
    var activeBytes = 0
    var frozenSegments = 0
    var usedIncrementalPath = false
}

struct MarkdownRenderSnapshot: Sendable {
    let content: AttributedString
    let highlightAfter: Int?
    let metrics: MarkdownRenderMetrics
}

/// Owns the mutable parse state outside MainActor. No SwiftUI or UIKit work is
/// performed here; Foundation's parser is the same backend used by Textual.
actor ChatMarkdownWorker {
    private struct Part {
        let source: String
        let content: AttributedString
        let maximumIdentity: Int
    }
    private enum JoinStyle: CaseIterable { case direct, previousNewline, nextNewline }
    private static let fixtures = [
        "first **bold**\n\nsecond _italic_", "# Heading\n\nbody\n\nlast",
        "before\n\n```swift\nlet x = 1\n```\nafter",
        "```\na\n```\n\n~~~text\nb\n~~~\nend",
        "你好🙂\n软换行\n\n第二段 café 👩🏽‍💻", "Title\n=====\n\nbody"
    ]
    // First use validates joins on THIS Foundation runtime. If it differs, use
    // the full parser; a performance optimization must never guess semantics.
    private static let joinStyle: JoinStyle? = JoinStyle.allCases.first { style in
        fixtures.allSatisfy { source in
            guard let full = try? parseFixture(source) else { return false }
            let plan = MarkdownBlockPlan.make(source)
            var output = AttributedString()
            var maximum = 0
            for piece in plan.complete + [plan.tail] where !piece.isEmpty {
                guard let raw = try? parseFixture(piece) else { return false }
                let shifted = renumber(raw, after: maximum)
                maximum = shifted.1
                output = append(output, shifted.0, style: style)
            }
            return equivalent(output, full)
        }
    }

    private var parts: [Part] = []
    private var prefix = AttributedString()
    private var lastSource = ""
    private var semanticFallback = false

    func render(_ source: String, finished: Bool) throws -> MarkdownRenderSnapshot {
        try Task.checkCancellation()
        if !source.hasPrefix(lastSource) { semanticFallback = false }
        lastSource = source
        let plan = MarkdownBlockPlan.make(source)
        var metrics = MarkdownRenderMetrics()
        metrics.activeBytes = plan.tail.utf8.count
        guard !finished, !semanticFallback, let style = Self.joinStyle, !plan.requiresWholeDocument else {
            parts.removeAll(); prefix = AttributedString()
            metrics.parsedBytes = source.utf8.count
            metrics.activeBytes = metrics.parsedBytes
            return MarkdownRenderSnapshot(content: try Self.parse(source), highlightAfter: finished ? nil : 0, metrics: metrics)
        }
        var common = 0
        while common < min(parts.count, plan.complete.count), parts[common].source == plan.complete[common] { common += 1 }
        let changedBoundary = common != parts.count || common != plan.complete.count
        if common < parts.count {
            parts.removeSubrange(common...)
            prefix = parts.reduce(AttributedString()) { Self.append($0, $1.content, style: style) }
        }
        var maximum = parts.last?.maximumIdentity ?? 0
        for piece in plan.complete.dropFirst(common) {
            try Task.checkCancellation()
            let shifted = Self.renumber(try Self.parse(piece), after: maximum)
            maximum = shifted.1
            prefix = Self.append(prefix, shifted.0, style: style)
            parts.append(Part(source: piece, content: shifted.0, maximumIdentity: maximum))
            metrics.parsedBytes += piece.utf8.count
        }
        let tail = Self.renumber(try Self.parse(plan.tail), after: maximum).0
        metrics.parsedBytes += plan.tail.utf8.count
        var output = Self.append(prefix, tail, style: style)
        // Validate newly frozen boundaries against the authoritative full parse.
        // Most streaming batches stay within the tail and skip this full pass.
        if changedBoundary {
            let canonical = try Self.parse(source)
            metrics.parsedBytes += source.utf8.count
            if !Self.equivalent(output, canonical) {
                semanticFallback = true
                parts.removeAll(); prefix = AttributedString()
                output = canonical
                maximum = 0
            }
        }
        metrics.frozenSegments = parts.count
        metrics.reusedBytes = parts.prefix(common).reduce(0) { $0 + $1.source.utf8.count }
        metrics.usedIncrementalPath = !semanticFallback && !parts.isEmpty
        return MarkdownRenderSnapshot(content: output, highlightAfter: maximum, metrics: metrics)
    }

    private static func parse(_ source: String) throws -> AttributedString {
        // Textual 0.5.0 performs this exact parse when no opt-in syntax
        // extensions are installed. Keep its custom attribute scope intact.
        try Task.checkCancellation()
        let result = try parseFixture(source)
        try Task.checkCancellation()
        return result
    }

    // Process-wide semantic capability detection must not be poisoned forever
    // by whichever document happens to be cancelled during the first render.
    private static func parseFixture(_ source: String) throws -> AttributedString {
        try AttributedString(markdown: source, including: \.textual, options: .init(), baseURL: nil)
    }

    private static func append(_ first: AttributedString, _ second: AttributedString, style: JoinStyle) -> AttributedString {
        guard !first.characters.isEmpty else { return second }
        guard !second.characters.isEmpty else { return first }
        var result = first
        if style != .direct, first.characters.last != "\n", second.characters.first != "\n" {
            let attributes = style == .previousNewline ? first.runs.last?.attributes : second.runs.first?.attributes
            result.append(AttributedString("\n", attributes: attributes ?? AttributeContainer()))
        }
        result.append(second)
        return result
    }

    /// Independent fragments start identities at 1. Keep every container/item
    /// identity distinct in the ONE final document, including nested tables.
    private static func renumber(_ value: AttributedString, after offset: Int) -> (AttributedString, Int) {
        let ids = Set(value.runs.flatMap { $0.presentationIntent?.components.map(\.identity) ?? [] }).sorted()
        let mapping = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, offset + $0.offset + 1) })
        var result = value
        for run in value.runs {
            guard let intent = run.presentationIntent else { continue }
            var parent: PresentationIntent?
            for component in intent.components.reversed() {
                parent = PresentationIntent(component.kind, identity: mapping[component.identity]!, parent: parent)
            }
            result[run.range].presentationIntent = parent
        }
        return (result, offset + ids.count)
    }

    private static func equivalent(_ left: AttributedString, _ right: AttributedString) -> Bool {
        renumber(left, after: 0).0 == renumber(right, after: 0).0
    }

    /// Runs only fixed local fixtures. No session contents, API or credentials.
    static func diagnostic() async -> String {
        let ticket = UUID()
        do { try await ChatRenderScheduler.shared.acquire(ticket, priority: .prefetch) }
        catch { return "检查已取消" }
        let report = await diagnosticBody()
        await ChatRenderScheduler.shared.release(ticket)
        return report
    }

    private static func diagnosticBody() async -> String {
        let sources = fixtures + [
            "- one\n\n  continuation\n- two", "| a | b |\n|---|---|\n| 1 | 2 |",
            "[later][ref]\n\n[ref]: https://example.com", "> quote\n>\n> continued", "```swift\nlet open = true\n",
            "<div>\ntext\n</div>", "    indented\n\n    code", "~~~text\n```\n~~~\nnext"
        ]
        var checks = 0
        var failures = 0
        var reused = 0
        for source in sources {
            if Task.isCancelled { return "检查已取消" }
            let worker = ChatMarkdownWorker()
            let characters = Array(source)
            for end in stride(from: 1, through: characters.count, by: 3) {
                let input = String(characters.prefix(end))
                do {
                    let result = try await worker.render(input, finished: false)
                    checks += 1
                    if !equivalent(result.content, try parse(input)) { failures += 1 }
                    reused += result.metrics.reusedBytes
                } catch { failures += 1 }
            }
            do {
                let final = try await worker.render(source, finished: true)
                checks += 1
                if !equivalent(final.content, try parse(source)) { failures += 1 }
            } catch { failures += 1 }
        }
        let longWorker = ChatMarkdownWorker()
        let prefix = (0..<100).map { "段落 \($0)，用于固定前文检查。\n\n" }.joined()
        _ = try? await longWorker.render(prefix, finished: false)
        var baselineBytes = 0
        var incrementalBytes = 0
        for count in 1...20 {
            if Task.isCancelled { return "检查已取消" }
            let input = prefix + String(repeating: "末尾", count: count)
            baselineBytes += input.utf8.count
            if let snapshot = try? await longWorker.render(input, finished: false) {
                incrementalBytes += snapshot.metrics.parsedBytes
                checks += 1
                if let full = try? parse(input), !equivalent(snapshot.content, full) { failures += 1 }
            } else { failures += 1 }
        }
        return "局部解析：\(joinStyle == nil ? "兼容回退" : "已启用")\n语义检查：\(checks) 次，\(failures) 个失败\n复用源字节：\(reused)\n固定前文示例解析字节：\(incrementalBytes) / 完整解析 \(baselineBytes)\n仅检查解析结果，不代表真机帧率。"
    }
}
