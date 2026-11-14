import Foundation

extension ModelTests {
    /// 纯图占位在服务端回写后是否仍能隐藏。
    ///
    /// 关键点：绑定必须来自「唯一命中」，不能靠文本/时间猜。
    @MainActor static func placeholderBindingTests() async throws {
        let payload = ChatAttachmentPayload(name: "a.png", path: "/inbox/a.png",
                                            mime: "image/png", size: 3, isImage: true)

        // 1) 唯一命中：服务端回写一行同样内容 → 绑定到它的真实 ID，文字保持隐藏
        do {
            let scope = "bind-unique-" + UUID().uuidString
            defer { ChatAttachmentPlaceholderStore.shared.removeScope(scope) }
            let service = EchoingService()
            let model = NativeChatModel(sessionID: "s1", api: service, displayScope: scope)
            await model.load()
            model.draft = ""
            _ = await model.send(attachments: [payload])
            await model.refresh()
            let users = model.transcript.messages.filter { $0.role == "user" }
            precondition(users.count == 1, "expected exactly one user row, got \(users.count)")
            let row = users[0]
            precondition(row.id == "srv-1", "expected the server row, got \(row.id)")
            let marks = ChatAttachmentPlaceholderStore.shared.markedIDs(scope: scope, sessionID: "s1")
            precondition(ChatAttachmentPlaceholder.hidesBody(
                messageID: row.id, content: row.content, role: row.role,
                attachmentCount: row.attachmentPaths.count, markedIDs: marks),
                "the confirmed server row must keep hiding the placeholder")
            model.disconnect()
            print("MODEL_PASS placeholder binds to the single confirmed server row")
        }

        // 2) 历史里已有同样文字 + 同样附件的旧消息：只绑定本次那一行
        do {
            let scope = "bind-history-" + UUID().uuidString
            defer { ChatAttachmentPlaceholderStore.shared.removeScope(scope) }
            let service = EchoingService()
            service.rows = [[
                "id": "srv-old", "role": "user", "content": ChatAttachmentPlaceholder.systemText,
                "timestamp": 900.0,
                "attachments": [["name": "a.png", "path": "/inbox/a.png", "mime": "image/png",
                                 "size": 3, "is_image": true]]
            ]]
            let model = NativeChatModel(sessionID: "s2", api: service, displayScope: scope)
            await model.load()
            model.draft = ""
            _ = await model.send(attachments: [payload])
            await model.refresh()
            let marks = ChatAttachmentPlaceholderStore.shared.markedIDs(scope: scope, sessionID: "s2")
            let rows = model.transcript.messages.filter { $0.role == "user" }
            precondition(rows.count == 2, "expected the old row and the new one, got \(rows.count)")
            let old = rows.first { $0.id == "srv-old" }
            let fresh = rows.first { $0.id == "srv-1" }
            precondition(old != nil && fresh != nil, "expected both server rows")
            precondition(!ChatAttachmentPlaceholder.hidesBody(
                messageID: "srv-old", content: old!.content, role: old!.role,
                attachmentCount: old!.attachmentPaths.count, markedIDs: marks),
                "the earlier identical row keeps its text: historyEnd excludes it")
            precondition(ChatAttachmentPlaceholder.hidesBody(
                messageID: "srv-1", content: fresh!.content, role: fresh!.role,
                attachmentCount: fresh!.attachmentPaths.count, markedIDs: marks),
                "only this send's row is bound")
            model.disconnect()
            print("MODEL_PASS an older identical row is never bound")
        }

        // 2b) 一次发送后出现两条同样新行：不猜，两条都显示文字
        do {
            let scope = "bind-ambiguous-" + UUID().uuidString
            defer { ChatAttachmentPlaceholderStore.shared.removeScope(scope) }
            let service = EchoingService()
            service.duplicateWrites = 2
            let model = NativeChatModel(sessionID: "s2b", api: service, displayScope: scope)
            await model.load()
            model.draft = ""
            _ = await model.send(attachments: [payload])
            await model.refresh()
            let marks = ChatAttachmentPlaceholderStore.shared.markedIDs(scope: scope, sessionID: "s2b")
            let rows = model.transcript.messages.filter { $0.role == "user" }
            precondition(rows.count == 2, "expected two ambiguous rows, got \(rows.count)")
            for row in rows {
                precondition(!ChatAttachmentPlaceholder.hidesBody(
                    messageID: row.id, content: row.content, role: row.role,
                    attachmentCount: row.attachmentPaths.count, markedIDs: marks),
                    "ambiguous matches must never hide text (row \(row.id))")
            }
            model.disconnect()
            print("MODEL_PASS ambiguous matches keep the text visible")
        }

        // 3) 附件路径不覆盖：不绑定
        do {
            let scope = "bind-attachment-" + UUID().uuidString
            defer { ChatAttachmentPlaceholderStore.shared.removeScope(scope) }
            let service = EchoingService()
            service.omitAttachments = true
            let model = NativeChatModel(sessionID: "s3", api: service, displayScope: scope)
            await model.load()
            model.draft = ""
            _ = await model.send(attachments: [payload])
            await model.refresh()
            let marks = ChatAttachmentPlaceholderStore.shared.markedIDs(scope: scope, sessionID: "s3")
            for row in model.transcript.messages where row.role == "user" {
                precondition(!ChatAttachmentPlaceholder.hidesBody(
                    messageID: row.id, content: row.content, role: row.role,
                    attachmentCount: row.attachmentPaths.count, markedIDs: marks),
                    "a row without the sent attachment must not be bound (row \(row.id))")
            }
            model.disconnect()
            print("MODEL_PASS a row missing the attachment is never bound")
        }

        // 4) 用户手打同样文字：不产生标记，回写后也保持可见
        do {
            let scope = "bind-manual-" + UUID().uuidString
            defer { ChatAttachmentPlaceholderStore.shared.removeScope(scope) }
            let service = EchoingService()
            let model = NativeChatModel(sessionID: "s4", api: service, displayScope: scope)
            await model.load()
            model.draft = ChatAttachmentPlaceholder.systemText
            _ = await model.send(attachments: [payload])
            await model.refresh()
            let marks = ChatAttachmentPlaceholderStore.shared.markedIDs(scope: scope, sessionID: "s4")
            precondition(marks.isEmpty, "manual text must not create a marker")
            for row in model.transcript.messages where row.role == "user" {
                precondition(!ChatAttachmentPlaceholder.hidesBody(
                    messageID: row.id, content: row.content, role: row.role,
                    attachmentCount: row.attachmentPaths.count, markedIDs: marks),
                    "manually typed placeholder text stays visible")
            }
            model.disconnect()
            print("MODEL_PASS manually typed placeholder text is never hidden")
        }

        // 5) 重发后绑定到新行，旧标记不残留
        do {
            let scope = "bind-retry-" + UUID().uuidString
            defer { ChatAttachmentPlaceholderStore.shared.removeScope(scope) }
            let service = EchoingService()
            service.failStart = true
            let model = NativeChatModel(sessionID: "s5", api: service, displayScope: scope)
            await model.load()
            model.draft = ""
            _ = await model.send(attachments: [payload])
            await model.refresh()
            precondition(model.canResendPending, "expected a resendable pending send")
            service.failStart = false
            service.nextID = "srv-retry"
            _ = await model.resendPending()
            await model.refresh()
            let marks = ChatAttachmentPlaceholderStore.shared.markedIDs(scope: scope, sessionID: "s5")
            precondition(marks == ["srv-retry"], "the retried row owns the marker, got \(marks)")
            for row in model.transcript.messages where row.role == "user" {
                precondition(row.id == "srv-retry", "only the retried row remains, got \(row.id)")
                precondition(ChatAttachmentPlaceholder.hidesBody(
                    messageID: row.id, content: row.content, role: row.role,
                    attachmentCount: row.attachmentPaths.count, markedIDs: marks),
                    "the retried row keeps hiding the placeholder")
            }
            model.disconnect()
            print("MODEL_PASS retry rebinds to the new server row and drops the old marker")
        }
    }
}

/// 回写服务端行的替身：模拟 chat/start 之后 history 里出现的真实用户行。
@MainActor final class EchoingService: NativeChatService {
    var rows: [[String: Any]] = []
    var active: String?
    var failStart = false
    var omitAttachments = false
    var nextID = "srv-1"
    /// 模拟服务端重复落库：一次发送写出多行完全相同的用户行。
    var duplicateWrites = 1
    private var started = 0

    func requiresAuthentication(after error: Error) -> Bool { false }

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        var s: [String: Any] = ["session_id": sessionID, "messages": rows,
                                "read_only": false, "_messages_offset": 0]
        if let active { s["active_stream_id"] = active }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: ["session": s]))
    }

    func startNativeTurn(sessionID: String, text: String) async throws -> String { nextID }
    func startNativeTurn(sessionID: String, text: String,
                         attachments: [ChatAttachmentPayload]) async throws -> String {
        if failStart { throw URLError(.timedOut) }
        started += 1
        let id = started == 1 ? nextID : "\(nextID)-\(started)"
        var row: [String: Any] = ["id": id, "role": "user", "content": text,
                                  "timestamp": 1_000.0 + Double(started)]
        if !omitAttachments {
            row["attachments"] = attachments.map {
                ["name": ($0.path as NSString).lastPathComponent, "path": $0.path,
                 "mime": $0.mime, "size": $0.size, "is_image": $0.isImage]
            }
        }
        for copy in 0..<max(1, duplicateWrites) {
            var written = row
            if copy > 0 { written["id"] = "\(id)-dup\(copy)" }
            rows.append(written)
        }
        active = "stream-\(started)"
        return active!
    }

    func stopNativeTurn(streamID: String) async throws { active = nil }
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws { }
}
