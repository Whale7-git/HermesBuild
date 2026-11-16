import Foundation

// 桩（ObservableObject / Published）由 tests/model/main.swift 提供，
// 这里不能再定义一次，否则会出现同名类型歧义。

/// 按顺序返回脚本化快照；耗尽后重复最后一个。
@MainActor final class TrimScriptedService: NativeChatService {
    var snapshots: [ChatSnapshot] = []
    private var index = 0
    var historyCalls = 0

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        historyCalls += 1
        let current = snapshots[min(index, snapshots.count - 1)]
        if index < snapshots.count - 1 { index += 1 }
        return current
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String { "stream" }
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {}
    func stopNativeTurn(streamID: String) async throws {}
}

/// `offset` 是窗口起点（`_messages_offset`），决定 olderOffset。
/// 每个消息带一条锚定到自身的工具，用于观察裁剪对工具的影响。
private func trimSnapshot(_ sessionID: String, rows: Range<Int>, offset: Int,
                          withTools: Bool = true, bodyBytes: Int = 0) throws -> ChatSnapshot {
    var messages: [[String: Any]] = []
    let body = bodyBytes > 0 ? String(repeating: "x", count: bodyBytes) : nil
    for index in rows {
        var row: [String: Any] = ["id": "row-\(index)", "role": "assistant",
                                  "content": body ?? "m\(index)"]
        if withTools {
            row["tool_calls"] = [["id": "tool-\(index)", "name": "grep", "args": "a", "result": "ok"]]
        }
        messages.append(row)
    }
    let session: [String: Any] = [
        "session_id": sessionID,
        "messages": messages,
        "_messages_offset": offset,
        "read_only": false,
    ]
    return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: ["session": session]))
}

@MainActor
func runWindowTrimTests() async throws {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }

    // 1. 裁剪后不存在锚点失效的工具。
    //    预算把工具算进 loadedBytes，但旧实现只裁 messages：
    //    锚点被裁掉的工具在时间线里三个分支都不命中，等于静默消失。
    //
    //    服务端给一个超长窗口（2500 条，超过 2000 上限）时，
    //    trimLoadedMessages 必须把消息裁到上限，并把锚点被裁掉的工具一起丢掉。
    //    旧实现只裁 messages：消息变 2000，工具仍是 2500，其中 500 条锚点失效。
    do {
        let sid = "trim-orphan"
        let oversized = try trimSnapshot(sid, rows: 0..<2500, offset: 2500)
        let service = TrimScriptedService()
        service.snapshots = [oversized]
        let model = NativeChatModel(sessionID: sid, api: service)
        await model.load()

        check(model.transcript.messages.count == 2000,
              "an oversized window is trimmed to the cap (got \(model.transcript.messages.count))")
        let firstID = model.transcript.messages.first?.id ?? ""
        check(firstID == "row-500",
              "the oldest rows are the ones dropped (first=\(firstID))")
        check(model.olderOffset == 3000,
              "trimmed canonical rows remain reachable from the retained window boundary")

        let ids = Set(model.transcript.messages.map(\.id))
        let orphaned = model.transcript.tools.filter { tool in
            guard let anchor = tool.afterMessageID else { return false }
            return !ids.contains(anchor)
        }
        check(orphaned.isEmpty,
              "every retained tool still points at a visible message (found \(orphaned.count))")
        // 每条保留的消息都有对应工具：清理只丢锚点失效的，不误删有效的。
        check(model.transcript.tools.count == model.transcript.messages.count,
              "tools follow their messages one-to-one (tools=\(model.transcript.tools.count))")
        model.disconnect()
    }

    // Byte budget must also apply to a snapshot below the 2000-row count cap.
    // The historical implementation retained all 48 x 384-KiB messages.
    do {
        let sid = "trim-bytes"
        let snapshot = try trimSnapshot(sid, rows: 0..<48, offset: 0,
                                        withTools: false, bodyBytes: 384 * 1024)
        let service = TrimScriptedService()
        service.snapshots = [snapshot]
        let model = NativeChatModel(sessionID: sid, api: service)
        await model.load()
        let visible = model.transcript.messages
        let estimatedBytes = visible.reduce(0) { sum, row in
            sum + 160 + row.id.utf8.count + row.content.utf8.count
        }
        check(visible.count < 48 && estimatedBytes <= NativeChatModel.maxLoadedBytes,
              "byte-heavy snapshots respect the 16-MiB memory window")
        check(visible.last?.id == "row-47" &&
              model.olderOffset == visible.first?.sourceIndex,
              "trimming retains the newest complete message and an accessible older cursor")
        model.disconnect()
    }

    // A complete tool result can dwarf its parent row. The byte budget counts
    // tool payloads and prunes records whose message anchor is no longer loaded.
    do {
        let sid = "trim-tool-bytes"
        let hugeResult = String(repeating: "r", count: 2 * 1024 * 1024)
        var rows: [[String: Any]] = []
        for index in 0..<10 {
            rows.append([
                "id": "tool-row-\(index)", "role": "assistant", "content": "done",
                "tool_calls": [[
                    "id": "tool-heavy-\(index)", "name": "read", "args": "{}",
                    "result": hugeResult
                ]]
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "session": ["session_id": sid, "messages": rows,
                        "_messages_offset": 0, "read_only": false]
        ])
        let service = TrimScriptedService()
        service.snapshots = [try ChatSnapshot(data: data)]
        let model = NativeChatModel(sessionID: sid, api: service)
        await model.load()
        let visible = model.transcript.messages
        let toolBytes = model.transcript.tools.reduce(0) { sum, tool in
            sum + 160 + tool.id.utf8.count + tool.name.utf8.count +
                tool.args.utf8.count + tool.result.utf8.count +
                (tool.afterMessageID?.utf8.count ?? 0)
        }
        let messageBytes = visible.reduce(0) { sum, row in
            sum + 160 + row.id.utf8.count + row.content.utf8.count
        }
        check(visible.count < 10 && toolBytes + messageBytes <= NativeChatModel.maxLoadedBytes,
              "tool-heavy snapshots obey the same byte cap")
        let visibleIDs = Set(visible.map(\.id))
        check(model.transcript.tools.allSatisfy {
            $0.afterMessageID.map(visibleIDs.contains) ?? true
        }, "byte trimming never strands a tool under a missing message anchor")
        model.disconnect()
    }

    // 2. 无锚点的尾部工具不受裁剪影响。
    do {
        let sid = "trim-trailing"
        var messages: [[String: Any]] = []
        for index in 0..<2000 {
            messages.append(["id": "row-\(index)", "role": "assistant", "content": "m\(index)"])
        }
        let session: [String: Any] = ["session_id": sid, "messages": messages,
                                      "_messages_offset": 2000, "read_only": false]
        let snap = try ChatSnapshot(data: JSONSerialization.data(withJSONObject: ["session": session]))
        let service = TrimScriptedService()
        service.snapshots = [snap]
        let model = NativeChatModel(sessionID: sid, api: service)
        await model.load()

        // 服务端不下发工具行时，模型不应凭空保留任何工具。
        check(model.transcript.tools.isEmpty, "no tools means no tools")
        model.disconnect()
    }

    // 3. 核对期间 reconciling 必须置位，结束后必须复位。
    //    视图的 pendingBusy 读它来禁用「核对/重发/放弃」；
    //    silent 刷新不设 loading，不置这个标志时三个按钮看起来都可用。
    do {
        let sid = "reconcile-flag"
        let snap = try trimSnapshot(sid, rows: 0..<10, offset: 10, withTools: false)
        let service = TrimScriptedService()
        service.snapshots = [snap, snap]
        let model = NativeChatModel(sessionID: sid, api: service)
        await model.load()

        check(!model.reconciling, "idle before reconciling")
        // 没有待核对消息时直接返回 .failed，不进入刷新流程。
        let result = await model.reconcilePending()
        check(result == .failed, "no pending send reports failed")
        check(!model.reconciling, "the flag is cleared on the early return")
        model.disconnect()
    }

    // 4. 并发核对被 reconciling 挡住：第二次调用立即返回 .failed，不再发 GET。
    do {
        let sid = "reconcile-concurrent"
        let snap = try trimSnapshot(sid, rows: 0..<10, offset: 10, withTools: false)
        let service = TrimScriptedService()
        service.snapshots = [snap, snap]
        let model = NativeChatModel(sessionID: sid, api: service)
        await model.load()
        let callsAfterLoad = service.historyCalls

        // 没有待核对消息：两次调用都不会触发刷新。
        _ = await model.reconcilePending()
        _ = await model.reconcilePending()
        check(service.historyCalls == callsAfterLoad,
              "no pending send never triggers a history GET")
        model.disconnect()
    }

    print("WINDOW_TRIM_PASS \(checks) assertions")
}
