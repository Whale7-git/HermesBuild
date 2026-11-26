import Combine
import SwiftUI

/// Draft, focus and toolbar changes never rebuild the message/tool timeline.
@MainActor
final class ChatTimelineProjection: ObservableObject {
    private struct Source: Equatable {
        let messages: [ChatMessage]
        let tools: [ChatTool]
        let notices: [ChatNotice]
        let running: Bool
        let toolsAreLive: Bool
        let transcriptRevision: UInt64
        let transcriptStructureRevision: UInt64
        let transcriptStructureID: UUID?

        static func == (lhs: Source, rhs: Source) -> Bool {
            lhs.messages == rhs.messages && lhs.tools == rhs.tools
                && lhs.notices == rhs.notices && lhs.running == rhs.running
                && lhs.toolsAreLive == rhs.toolsAreLive
        }

        var streamingTailSnapshot: ChatStreamingTailSnapshot {
            ChatStreamingTailSnapshot(
                messages: messages, tools: tools, notices: notices,
                running: running, toolsAreLive: toolsAreLive,
                transcriptRevision: transcriptRevision,
                transcriptStructureRevision: transcriptStructureRevision,
                transcriptStructureID: transcriptStructureID)
        }
    }
    @Published private(set) var items: [ChatRowItem] = [] {
        didSet { itemsVersion &+= 1 }
    }
    private let itemsOwner = UUID()
    private var itemsVersion: UInt64 = 0
    var itemsStamp: ChatTimelineItemsStamp {
        ChatTimelineItemsStamp(owner: itemsOwner, version: itemsVersion)
    }
    private var subscription: AnyCancellable?
    private var previousSource: Source?
    /// Message ID → rendered row index; refreshed only on a structural
    /// projection rebuild. A streaming token now locates its host in O(1).
    private var itemIndexByID: [String: Int] = [:]
    /// A tool's owning row cannot change on a payload-only update. Cache this
    /// mapping alongside the structural row index instead of rediscovering it
    /// by walking every visible row for every tool progress event.
    private var toolRowByID: [String: String] = [:]
    private var toolIndicesByRowID: [String: [Int]] = [:]
    /// Turns that first appeared at the top edge of a history window are kept
    /// as normal rows permanently. If a later prepend reveals their original
    /// user row, regrouping that turn would replace a visible row id and defeat
    /// the scroll anchor. Other completed turns can still use process rows.
    private var protectedLeadingTurnIDs = Set<String>()

    init(model: NativeChatModel) {
        // 相位收敛后，原来订阅 5 个布尔（running/uncertain/reconnecting/suspended/
        // streamConnected）改成订阅一个 phase + 两个正交事实。组合逻辑仍然只有
        // 这一处，但因为相位互斥，不会出现「running 与 reconnecting 同时为真」
        // 这种原先会让 live 判断失真的组合。
        let live = model.$phase
            .combineLatest(model.$uncertain, model.$suspended)
            .map { phase, uncertain, suspended in
                phase.isRunning && phase.isConnected && !uncertain && !suspended
            }
            .removeDuplicates()
        subscription = model.$transcript.combineLatest(model.$phase, live)
            .map { transcript, phase, toolsAreLive in
                Source(messages: transcript.messages, tools: transcript.tools,
                       notices: transcript.notices,
                       running: phase.isRunning && !transcript.terminal,
                       toolsAreLive: toolsAreLive && !transcript.terminal,
                       transcriptRevision: transcript.transcriptRevision,
                       transcriptStructureRevision: transcript.transcriptStructureRevision,
                       transcriptStructureID: transcript.transcriptStructureID)
            }
            .sink { [weak self] source in
                guard let self else { return }
                let projectionSample = ChatPerformanceRecorder.shared.begin()
                defer {
                    ChatPerformanceRecorder.shared.finish(.timelineProjection, projectionSample)
                }
                if let previous = self.previousSource {
                    // Streaming text is the overwhelmingly common update.
                    // Probe the verified tail-only fast path BEFORE running a
                    // second whole-history Source equality scan.
                    if let updated = self.fastStreamingUpdate(from: previous, to: source) {
                        self.previousSource = source
                        self.items = updated
                        return
                    }
                    if source == previous {
                        self.previousSource = source
                        return
                    }
                    if let updated = self.fastToolUpdate(from: previous, to: source) {
                        self.previousSource = source
                        self.items = updated
                        return
                    }
                }
                self.previousSource = source
                let tail = source.running && source.messages.last?.role == "assistant"
                    ? source.messages.last?.id : nil
                let activeTools = source.toolsAreLive
                    ? ChatActivity.activeToolIDs(messages: source.messages, tools: source.tools) : []
                let turnIDs = ChatTimeline.turnIDs(for: source.messages)
                let userTurnIDs = source.messages.compactMap { message in
                    message.role == "user" ? turnIDs[message.id] : nil
                }
                if let leading = userTurnIDs.first {
                    self.protectedLeadingTurnIDs.insert(leading)
                }
                var completed = Set(userTurnIDs.dropLast())
                if !source.running, let tail = userTurnIDs.last {
                    completed.insert(tail)
                }
                let foldable = completed.subtracting(self.protectedLeadingTurnIDs)
                let projected = ChatTimeline.build(
                    messages: source.messages, tools: source.tools,
                    notices: source.notices, running: source.running,
                    completeTurnIDs: foldable)
                    .map { row in
                        let toolsAreLive: Bool
                        if case .tools(let tools) = row.kind {
                            toolsAreLive = tools.contains { activeTools.contains($0.id) }
                        } else if case .process(let group) = row.kind {
                            toolsAreLive = group.tools.contains { activeTools.contains($0.id) }
                        } else { toolsAreLive = false }
                        return ChatRowItem(row: row, isStreaming: row.id == "m-\(tail ?? "")", toolsAreLive: toolsAreLive)
                    }
                self.itemIndexByID = Dictionary(
                    projected.enumerated().map { ($0.element.id, $0.offset) },
                    uniquingKeysWith: { first, _ in first })
                var toolRows: [String: String] = [:]
                var toolIndices: [String: [Int]] = [:]
                let sourceIndices = Dictionary(source.tools.enumerated().map { ($0.element.id, $0.offset) },
                    uniquingKeysWith: { first, _ in first })
                var validOwnership = sourceIndices.count == source.tools.count
                for item in projected {
                    let rowTools: [ChatTool]
                    switch item.row.kind {
                    case .tools(let values): rowTools = values
                    case .process(let group): rowTools = group.tools
                    default: continue
                    }
                    for tool in rowTools {
                        guard toolRows[tool.id] == nil, let index = sourceIndices[tool.id] else {
                            validOwnership = false; continue
                        }
                        toolRows[tool.id] = item.id
                        toolIndices[item.id, default: []].append(index)
                    }
                }
                self.toolRowByID = validOwnership ? toolRows : [:]
                self.toolIndicesByRowID = validOwnership ? toolIndices : [:]
                self.items = projected
            }
    }

    /// The live tail is the only row that changes on every token batch. If all
    /// row identities, roles, tools, notices and phase facts are unchanged,
    /// replace that one message in place instead of rebuilding dictionaries and
    /// regrouping up to 2,000 rows every 40–140 ms. Any structural change takes
    /// the normal full projection path.
    private func fastStreamingUpdate(from previous: Source,
                                     to next: Source) -> [ChatRowItem]? {
        guard ChatStreamingTailProof.canReplaceTail(
                from: previous.streamingTailSnapshot,
                to: next.streamingTailSnapshot),
              let newLast = next.messages.last,
              let index = itemIndexByID["m-\(newLast.id)"],
              items.indices.contains(index),
              items[index].id == "m-\(newLast.id)" else {
            return nil
        }
        var updated = items
        updated[index] = updated[index].replacingMessage(newLast)
        return updated
    }

    /// A tool event can update one already-visible group. Rebuild only when the
    /// IDs, order or anchors change; payload-only updates keep the row and its
    /// measured viewport anchor stable.
    private func fastToolUpdate(from previous: Source,
                                to next: Source) -> [ChatRowItem]? {
        guard previous.messages == next.messages,
              previous.notices == next.notices,
              previous.running == next.running,
              previous.toolsAreLive == next.toolsAreLive,
              previous.tools.count == next.tools.count,
              previous.tools.count > 0 else { return nil }
        // Check structural identity and detect payload changes in one scan,
        // without allocating two ID and anchor arrays per tool event.
        var changedRows = Set<String>()
        for index in previous.tools.indices {
            let old = previous.tools[index], new = next.tools[index]
            guard old.id == new.id, old.afterMessageID == new.afterMessageID else {
                return nil
            }
            if old != new {
                guard let rowID = toolRowByID[old.id] else { return nil }
                changedRows.insert(rowID)
            }
        }
        guard !changedRows.isEmpty else { return nil }
        let activeTools = next.toolsAreLive
            ? ChatActivity.activeToolIDs(messages: next.messages, tools: next.tools) : []
        // Materialize only the changed groups, using the exact structural
        // order. Unchanged groups no longer allocate and compare payload arrays.
        var updated = items
        for rowID in changedRows {
            guard let indices = toolIndicesByRowID[rowID],
                  indices.allSatisfy({ next.tools.indices.contains($0) }) else { return nil }
            let replacement = indices.map { next.tools[$0] }
            guard let index = itemIndexByID[rowID],
                  let value = updated[index].replacingTools(
                    replacement,
                    toolsAreLive: replacement.contains { activeTools.contains($0.id) })
            else { return nil }
            updated[index] = value
        }
        return updated
    }
}
