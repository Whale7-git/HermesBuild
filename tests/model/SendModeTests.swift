import Foundation

/// 运行中发送的三条路径。共同约束：
/// - 只有 `accepted` 才能清草稿；
/// - steer 被拒要降级成排队并告知，不能假装送达；
/// - interrupt 必须先确认停止，停止失败就不发（否则两条回复同时跑）。
@MainActor final class SteerService: NativeChatService {
    var steerCalls = 0
    var stopCalls = 0
    var startCalls = 0
    var lastSteerText: String?
    /// nil 表示受理；非 nil 是服务端给出的降级原因。
    var steerResult: String?
    var steerThrows = false
    var active: String?
    var rows: [[String: Any]] = []

    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        var s: [String: Any] = ["session_id": sessionID, "messages": rows,
                                "read_only": false, "_messages_offset": 0]
        if let active { s["active_stream_id"] = active }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: ["session": s]))
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        startCalls += 1
        rows.append(["id": "user-\(startCalls)", "role": "user", "content": text])
        active = "test-stream"
        return active!
    }
    func stopNativeTurn(streamID: String) async throws {
        stopCalls += 1
        active = nil
        // This fixture models a confirmed stop, including authoritative history.
        // An acknowledgement alone must not unlock a durable accepted-run receipt.
        rows.append(["id": "answer-\(startCalls)", "role": "assistant", "content": "stopped"])
    }
    func steerNativeTurn(sessionID: String, text: String) async throws -> String? {
        steerCalls += 1
        lastSteerText = text
        if steerThrows { throw URLError(.timedOut) }
        return steerResult
    }
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
}

@MainActor
func runSendModeTests() async {
    // steer 受理：草稿清空，不产生新一轮 start。
    do {
        let service = SteerService()
        let model = NativeChatModel(sessionID: "s1", api: service, draftStore: nil, historyStore: nil)
        await model.load(silent: true)
        model.draft = "先跑着"
        _ = await model.send()
        precondition(model.running, "首条应进入运行态")

        model.sendMode = .steer
        model.draft = "顺便看下日志"
        let accepted = await model.send()
        precondition(accepted, "运行中 steer 应被本地接受")
        precondition(service.steerCalls == 1, "steer 应只调用一次")
        precondition(service.lastSteerText == "顺便看下日志", "steer 文本必须原样送出")
        precondition(model.draft.isEmpty, "受理后清空草稿")
        precondition(model.queuedText == nil, "受理不应进入队列")
        precondition(service.startCalls == 1, "steer 不发起新的一轮")
        await model.stop()
    }

    // steer 被拒：降级为排队，草稿清空但内容不丢，且必须给出可见提示。
    do {
        let service = SteerService()
        service.steerResult = "not_running"
        let model = NativeChatModel(sessionID: "s2", api: service, draftStore: nil, historyStore: nil)
        await model.load(silent: true)
        model.draft = "先跑着"
        _ = await model.send()
        model.sendMode = .steer
        model.draft = "这条进不去"
        _ = await model.send()
        precondition(model.queuedText == "这条进不去", "被拒的 steer 必须留在队列里")
        precondition(model.draft.isEmpty, "已转入队列，草稿应清空")
        precondition(model.notice?.contains("排队") == true, "被拒必须提示改为排队")
        precondition(service.startCalls == 1, "降级也不立刻发新的一轮")
        await model.stop()
    }

    // steer 网络失败：草稿保留，不回退成排队（否则用户以为已送达）。
    do {
        let service = SteerService()
        service.steerThrows = true
        let model = NativeChatModel(sessionID: "s3", api: service, draftStore: nil, historyStore: nil)
        await model.load(silent: true)
        model.draft = "先跑着"
        _ = await model.send()
        model.sendMode = .steer
        model.draft = "会失败"
        let accepted = await model.send()
        precondition(!accepted, "失败不应报告成功")
        precondition(model.draft == "会失败", "失败必须保留草稿")
        precondition(model.queuedText == nil, "失败不能假装进了队列")
        await model.stop()
    }

    // queue：只挂起，不发；本轮结束后才发。
    do {
        let service = SteerService()
        let model = NativeChatModel(sessionID: "s4", api: service, draftStore: nil, historyStore: nil)
        await model.load(silent: true)
        model.draft = "先跑着"
        _ = await model.send()
        model.sendMode = .queue
        model.draft = "等会儿发"
        _ = await model.send()
        precondition(model.queuedText == "等会儿发", "queue 应挂起")
        precondition(service.startCalls == 1, "queue 运行中不立即发送")
        precondition(service.steerCalls == 0, "queue 不走 steer")
        await model.stop()
    }

    // interrupt：先停止，再作为新消息发出。
    do {
        let service = SteerService()
        let model = NativeChatModel(sessionID: "s5", api: service, draftStore: nil, historyStore: nil)
        await model.load(silent: true)
        model.draft = "先跑着"
        _ = await model.send()
        model.sendMode = .interrupt
        model.draft = "别跑了"
        _ = await model.send()
        precondition(service.stopCalls == 1, "interrupt 必须先停止本轮")
        precondition(service.startCalls == 2, "停止后应作为新消息发出")
        precondition(model.queuedText == nil, "interrupt 不进入队列")
        await model.stop()
    }
}
@MainActor
func runQueuePresentationTests() {
    precondition(ChatQueuedDelivery.waiting.statusLabel == nil, "waiting queue is quiet")
    precondition(ChatQueuedDelivery.submitting.statusLabel == "正在提交",
                 "submitting queue state is visible")
    precondition(ChatQueuedDelivery.uncertain.statusLabel == "结果待核对",
                 "uncertain queue state asks for attention")
}
