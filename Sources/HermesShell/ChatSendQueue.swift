import Foundation

/// A complete turn waiting behind the active response.
///
/// The attachment payload is retained until the turn is actually submitted.
/// Persisted records use the same JSON shape as the old single-slot queue, so
/// an update can recover a queue written by build117 without turning an image
/// message into a text-only placeholder.
struct ChatQueuedTurn: Identifiable, Equatable {
    static let maximumCount = 20
    /// Only IDs newer than the saved history boundary matter for recovery.
    /// A long transcript must not turn one queue record into an unbounded blob.
    static let maximumKnownIDs = 256

    let id: String
    var text: String
    var attachments: [ChatAttachmentPayload]
    var composerText: String
    var origin: ChatSendOrigin
    /// The stream after which this turn may be dispatched automatically.
    /// `nil` means a restored/manual turn and prevents an unrelated completion
    /// from sending it.
    var automaticAfterStreamID: String?
    /// Local dispatch state. A turn remains persisted until the server accepts
    /// its POST; an interrupted submission is never silently dropped.
    var delivery: ChatQueuedDelivery
    /// Authoritative history boundary captured immediately before POST. These
    /// three fields are the evidence used after a process restart: only rows
    /// after this boundary, absent from `knownIDs`, can prove that the turn
    /// reached the server. Version 2/3 records have no boundary and therefore
    /// remain fail-closed until the user explicitly discards them.
    var historyEnd: Int?
    var knownIDs: Set<String>
    var submittedAt: Double?

    init(id: String = "queued-" + UUID().uuidString, text: String,
         attachments: [ChatAttachmentPayload], composerText: String,
         origin: ChatSendOrigin, automaticAfterStreamID: String?,
         delivery: ChatQueuedDelivery = .waiting,
         historyEnd: Int? = nil, knownIDs: Set<String> = [],
         submittedAt: Double? = nil) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.composerText = composerText
        self.origin = origin
        self.automaticAfterStreamID = automaticAfterStreamID
        self.delivery = delivery
        self.historyEnd = historyEnd
        self.knownIDs = knownIDs
        self.submittedAt = submittedAt
    }

    var isWaiting: Bool { delivery == .waiting }

    /// In-place editing retains identity, attachments, ordering and the
    /// original stream gate. No change is allowed to an uncertain POST.
    func edited(composerText: String, attachmentOnlyText: String) -> ChatQueuedTurn? {
        guard isWaiting else { return nil }
        let typed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty else { return nil }
        var next = self
        next.composerText = composerText
        next.text = typed.isEmpty ? attachmentOnlyText : typed
        next.origin = typed.isEmpty ? .systemPlaceholder : .userInput
        next.historyEnd = nil
        next.knownIDs = []
        next.submittedAt = nil
        return next
    }

    /// A restored or interrupted submission cannot be resent automatically.
    var needsReconcile: Bool { delivery == .uncertain || delivery == .submitting }

    var summary: String {
        let filenames = attachments.map(\.name).joined(separator: "、")
        return filenames.isEmpty ? text : "\(text)\n附件：\(filenames)"
    }

    var hasRecoveryEvidence: Bool {
        guard let historyEnd, historyEnd >= 0, submittedAt?.isFinite == true,
              knownIDs.count <= Self.maximumKnownIDs else { return false }
        return true
    }

    /// Resolve a restored in-flight turn against an authoritative history
    /// window. A unique matching user row proves delivery. Absence is only
    /// accepted when the window covers the saved boundary, contains no other
    /// new user row, and has no active server run.
    func resolution(in snapshot: ChatSnapshot) -> PendingReconcileResult {
        DeliveryReconciliationPolicy.resolve(
            text: text, attachments: attachments, historyEnd: historyEnd,
            knownIDs: knownIDs, snapshot: snapshot)
    }
}

/// One conservative history reconciliation policy for manual and queued POSTs.
/// Without a server-issued receipt, multiple new user rows are ambiguous even
/// when only one echoes our text. Never unlock automatic resend on ambiguity.
enum DeliveryReconciliationPolicy {
    static func resolve(text: String, attachments: [ChatAttachmentPayload],
                        historyEnd: Int?, knownIDs: Set<String>,
                        snapshot: ChatSnapshot) -> PendingReconcileResult {
        guard let historyEnd, historyEnd >= 0,
              !snapshot.readOnly,
              snapshot.rawMessageEndIndex >= historyEnd,
              snapshot.olderOffset <= historyEnd else { return .failed }
        let newer = snapshot.messages.filter {
            $0.role == "user" && ($0.sourceIndex ?? -1) >= historyEnd
                && !knownIDs.contains($0.id)
        }
        if newer.count == 1, let only = newer.first {
            let expected = Set(attachments.map(\.path))
            if only.content.trimmingCharacters(in: .whitespacesAndNewlines) == text,
               expected.isSubset(of: Set(only.attachmentPaths)) {
                return .delivered
            }
        }
        // No new user row + no active run is the only trustworthy absence proof
        // available with this protocol. Any other case remains locked.
        if newer.isEmpty && snapshot.activeStreamID == nil { return .absent }
        return .failed
    }
}

/// Delivery state is local-only. It never grants permission to resend; an
/// uncertain turn must be reconciled or discarded explicitly.
enum ChatQueuedDelivery: String, Equatable {
    case waiting
    case submitting
    case uncertain

    var statusLabel: String? {
        switch self {
        case .waiting: nil
        case .submitting: "正在提交"
        case .uncertain: "结果待核对"
        }
    }
}

/// One queue summary shared by the composer, manager and recovery center.
/// Status is derived from every turn so warning colour and copy cannot drift.
struct ChatQueueStatus: Equatable {
    let waiting: Int
    let submitting: Int
    let uncertain: Int

    var total: Int { waiting + submitting + uncertain }
    var needsAttention: Bool { uncertain > 0 }
    var isEmpty: Bool { total == 0 }

    init(turns: [ChatQueuedTurn]) {
        var waiting = 0
        var submitting = 0
        var uncertain = 0
        for turn in turns {
            switch turn.delivery {
            case .waiting: waiting += 1
            case .submitting: submitting += 1
            case .uncertain: uncertain += 1
            }
        }
        self.waiting = waiting
        self.submitting = submitting
        self.uncertain = uncertain
    }

    var summary: String {
        guard !isEmpty else { return "队列为空" }
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) 条待发送") }
        if submitting > 0 { parts.append("\(submitting) 条正在提交") }
        if uncertain > 0 { parts.append("\(uncertain) 条待核对") }
        return parts.joined(separator: " · ")
    }

    var compactSummary: String {
        guard !isEmpty else { return "队列为空" }
        if uncertain > 0 {
            return "\(total) 条 · \(uncertain) 条待核对"
        }
        if submitting > 0 {
            return "\(total) 条 · \(submitting) 条正在提交"
        }
        return "\(total) 条待发送"
    }
}

/// Versioned encoding for the multi-turn queue.
///
/// Version 1 is the build117 single-object shape. Version 2 is the build119
/// multi-turn shape. Version 3 added delivery state. Version 4 adds the
/// pre-POST history boundary, known IDs and submission time so a queue restored
/// after process termination can be reconciled before it is ever resent.
/// Malformed records are rejected as a whole instead of silently dropping only
/// some attachment references.
enum ChatSendQueueCodec {
    static let storageVersion = 4

    static func encode(_ turns: [ChatQueuedTurn]) -> Data? {
        guard turns.count <= ChatQueuedTurn.maximumCount else { return nil }
        let records = turns.map(record)
        guard JSONSerialization.isValidJSONObject(records) else { return nil }
        let root: [String: Any] = ["version": storageVersion, "items": records]
        guard JSONSerialization.isValidJSONObject(root) else { return nil }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> [ChatQueuedTurn]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let rawItems = root["items"] as? [[String: Any]] {
            guard let rawVersion = root["version"] as? NSNumber,
                  (2...storageVersion).contains(rawVersion.intValue),
                  rawItems.count <= ChatQueuedTurn.maximumCount else { return nil }
            let version = rawVersion.intValue
            let decoded = rawItems.compactMap { decodeTurn($0, version: version) }
            guard decoded.count == rawItems.count else { return nil }
            // SwiftUI identifies rows by id. Reject duplicate ids instead of
            // silently binding controls to the wrong queued turn.
            guard Set(decoded.map(\.id)).count == decoded.count else { return nil }
            return decoded
        }
        // build117 persisted one turn without a version wrapper.
        guard let legacy = decodeTurn(root, version: 1) else { return nil }
        return [ChatQueuedTurn(id: "legacy-queued-turn", text: legacy.text,
                               attachments: legacy.attachments,
                               composerText: legacy.composerText,
                               origin: legacy.origin,
                               automaticAfterStreamID: nil)]
    }

    private static func record(_ turn: ChatQueuedTurn) -> [String: Any] {
        ["id": turn.id, "text": turn.text, "composer_text": turn.composerText,
         "delivery": turn.delivery.rawValue,
         "attachments": turn.attachments.map(\.jsonObject),
         "system_placeholder": turn.origin == .systemPlaceholder,
         "automatic_after_stream_id": turn.automaticAfterStreamID ?? NSNull(),
         "history_end": turn.historyEnd ?? NSNull(),
         "known_ids": turn.knownIDs.sorted(),
         "submitted_at": turn.submittedAt ?? NSNull()]
    }

    private static func decodeTurn(_ object: [String: Any], version: Int) -> ChatQueuedTurn? {
        guard let text = object["text"] as? String, !text.isEmpty,
              let composerText = object["composer_text"] as? String,
              let refs = object["attachments"] as? [[String: Any]] else { return nil }
        let attachments = refs.compactMap { ref -> ChatAttachmentPayload? in
            guard let name = ref["name"] as? String,
                  let path = ref["path"] as? String, !path.isEmpty,
                  let mime = ref["mime"] as? String,
                  let size = ref["size"] as? Int, size >= 0,
                  let isImage = ref["is_image"] as? Bool else { return nil }
            return ChatAttachmentPayload(name: name, path: path, mime: mime,
                                         size: size, isImage: isImage)
        }
        guard attachments.count == refs.count else { return nil }
        let id = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "queued-" + UUID().uuidString
        let automatic = (object["automatic_after_stream_id"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        // Version 2 had no delivery field. A process cannot have restored an
        // actually in-flight turn there, so `.waiting` is the only safe default.
        let delivery = (object["delivery"] as? String)
            .flatMap(ChatQueuedDelivery.init(rawValue:)) ?? .waiting
        let historyEnd: Int?
        let knownIDs: Set<String>
        let submittedAt: Double?
        if version >= 4 {
            if object["history_end"] is NSNull {
                historyEnd = nil
            } else if let value = object["history_end"] as? Int, value >= 0 {
                historyEnd = value
            } else {
                return nil
            }
            guard let rawKnownIDs = object["known_ids"] as? [String],
                  rawKnownIDs.allSatisfy({ !$0.isEmpty }),
                  rawKnownIDs.count <= ChatQueuedTurn.maximumKnownIDs,
                  Set(rawKnownIDs).count == rawKnownIDs.count else { return nil }
            knownIDs = Set(rawKnownIDs)
            if object["submitted_at"] is NSNull {
                submittedAt = nil
            } else if let value = object["submitted_at"] as? Double, value.isFinite, value > 0 {
                submittedAt = value
            } else {
                return nil
            }
        } else {
            historyEnd = nil
            knownIDs = []
            submittedAt = nil
        }
        return ChatQueuedTurn(id: id, text: text, attachments: attachments,
                              composerText: composerText,
                              origin: object["system_placeholder"] as? Bool == true
                                  ? .systemPlaceholder : .userInput,
                              automaticAfterStreamID: automatic,
                              delivery: delivery, historyEnd: historyEnd,
                              knownIDs: knownIDs, submittedAt: submittedAt)
    }
}

/// Pure transition used by dispatch and persistence tests. Only a waiting turn
/// may start a POST, and only an accepted result removes it.
enum ChatQueueDispatchPlan: Equatable {
    case blocked
    case dispatch(index: Int)
    case reconcile(index: Int)

    static func make(turns: [ChatQueuedTurn], completedStreamID: String?,
                     paused: Bool, editing: Bool = false) -> Self {
        guard !editing, let first = turns.first else { return .blocked }
        if first.needsReconcile { return .reconcile(index: 0) }
        guard first.delivery == .waiting else { return .blocked }
        if completedStreamID != nil && paused { return .blocked }
        if let completedStreamID,
           first.automaticAfterStreamID != completedStreamID { return .blocked }
        return .dispatch(index: 0)
    }
}

/// Pure queue ordering used by the management sheet. SwiftUI's drag callback
/// reports insertion offsets against the pre-move array; normalizing that here
/// keeps the persisted queue deterministic and testable without UIKit.
enum ChatQueueOrdering {
    /// Reconciliation work must never sit behind ordinary queued text. The
    /// sort is stable within each state, preserving the user's chosen order.
    static func prioritize(_ turns: [ChatQueuedTurn]) -> [ChatQueuedTurn] {
        turns.enumerated().sorted { left, right in
            let leftPriority = priority(left.element.delivery)
            let rightPriority = priority(right.element.delivery)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func priority(_ delivery: ChatQueuedDelivery) -> Int {
        switch delivery {
        case .uncertain: return 0
        case .submitting: return 1
        case .waiting: return 2
        }
    }

    static func move(_ turns: [ChatQueuedTurn], fromOffsets: IndexSet,
                     toOffset: Int) -> [ChatQueuedTurn] {
        guard !fromOffsets.isEmpty, turns.count <= ChatQueuedTurn.maximumCount,
              fromOffsets.allSatisfy({ turns.indices.contains($0) }) else { return turns }
        var next = turns
        let moving = fromOffsets.sorted().map { turns[$0] }
        for index in fromOffsets.sorted(by: >) {
            next.remove(at: index)
        }
        let removedBeforeTarget = fromOffsets.filter { $0 < toOffset }.count
        let insertion = min(next.count, max(0, toOffset - removedBeforeTarget))
        next.insert(contentsOf: moving, at: insertion)
        return next
    }
}
