import Foundation

/// 网关 `/v1/runs/{id}/events`（源码 `gateway/platforms/api_server_runs.py`）与 App 流式状态机
/// `ChatTranscript.apply(_:)` 之间的事件翻译层。
///
/// 网关发 `message.delta` / `run.completed` 这一类点号事件，App 只认 `token` / `done` 这一类
/// 短事件；这里做纯函数转换，不持有状态、不抛错。
enum GatewayEventMap {

    /// 把一帧网关 SSE 翻译成 0..n 个 App 帧。
    ///
    /// - 无法识别的事件、JSON 解析失败、字段缺失或类型不符：一律返回空数组。
    ///   这里绝不抛错——单帧坏数据不能中断整条流。
    /// - 输出帧一律继承输入帧的 `id`：`ChatTranscript` 用 `seenEventIDs` 按 id 去重，
    ///   断线重连续传时必须靠同一个 id 判断「这帧已经渲染过」，漏了就会重复渲染。
    static func map(_ frame: SSEFrame) -> [SSEFrame] {
        // 网关 `/v1/runs/{id}/events` 不发 SSE 的 `event:` 行，事件名放在 data JSON 的
        // `"event"` 字段里（`SSEParser` 得到的 frame.event 恒为 "message"）。WebUI 的
        // chat/stream 端点则发 `event:` 行。这里两边都认：优先 data JSON 的 event 字段。
        guard let body = object(from: frame.data) else { return [] }
        // 严格取字符串，不做任意类型强转；data JSON 的 event 与 SSE `event:` 行
        // 冲突时丢弃该帧（可能是代理改写或伪造），避免 confused deputy。
        let jsonEvent = body["event"] as? String
        let sseEvent = frame.event.lowercased() == "message" ? nil : frame.event
        let rawName: String?
        if let jsonEvent, !jsonEvent.trimmingCharacters(in: .whitespaces).isEmpty {
            if let sseEvent, sseEvent.trimmingCharacters(in: .whitespaces).lowercased()
                != jsonEvent.trimmingCharacters(in: .whitespaces).lowercased() {
                return []
            }
            rawName = jsonEvent
        } else {
            rawName = sseEvent
        }
        guard let name = rawName?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !name.isEmpty, name != "message" else { return [] }

        switch name {
        case "message.delta":
            // 增量正文，最常见的一帧。
            guard let delta = text(body["delta"]) else { return [] }
            return emit("token", ["text": delta], id: frame.id)

        case "message.interim":
            // The deployed gateway marks commentary already delivered through deltas.
            guard boolean(body["already_streamed"]) != true else { return [] }
            guard let interim = text(body["text"]) ?? text(body["interim"]) else { return [] }
            return emit("token", ["text": interim], id: frame.id)

        case "reasoning.available":
            guard let reasoning = text(body["text"]) else { return [] }
            return emit("reasoning", ["text": reasoning], id: frame.id)

        case "tool.started":
            guard let tool = toolName(body) else { return [] }
            var payload: [String: Any] = ["name": tool]
            if let tid = toolCallID(body) { payload["tid"] = tid }
            if let preview = text(body["preview"]) { payload["preview"] = preview }
            // args 原样透传（可能是对象或数组），交给 App 侧 displayValue 决定怎么显示。
            if let args = body["args"], !(args is NSNull) { payload["args"] = args }
            return emit("tool", payload, id: frame.id)

        case "tool.completed":
            guard let tool = toolName(body) else { return [] }
            var payload: [String: Any] = [
                "name": tool,
                // 网关字段叫 error（布尔），App 叫 is_error，这里改名而不是透传。
                "is_error": boolean(body["error"]) ?? false
            ]
            if let tid = toolCallID(body) { payload["tid"] = tid }
            if let preview = text(body["preview"]) ?? text(body["result"]) ?? text(body["output"]) {
                payload["preview"] = preview
            }
            return emit("tool_complete", payload, id: frame.id)

        case "run.completed":
            return completed(body, id: frame.id)

        case "run.interrupted":
            return emit("cancel", ["message": "interrupted"], id: frame.id)

        case "run.cancelled":
            return emit("cancel", ["message": "cancelled"], id: frame.id)

        case "run.failed":
            return emit("apperror", ["message": text(body["error"]) ?? "回复任务失败"], id: frame.id)

        case "approval.responded":
            var payload: [String: Any] = [:]
            if let requestID = text(body["request_id"]) { payload["request_id"] = requestID }
            return emit("approval_resolved", payload, id: frame.id)

        case "replay.truncated":
            return emit("apperror", ["message": "回复续传窗口已过期，请刷新核对完整历史"], id: frame.id)

        case "approval.request":
            // 用户要看着这条描述做决定，描述按 description → command → tool 依次兜底。
            // 除了文案，还必须把 `choices` 和 `request_id` 带出去：可选项由服务端决定
            // （可能是 once/deny 两项，也可能带 session/always 四项），客户端不该猜；
            // request_id 用来精确命中，同一 run 上可能同时挂着多个待批请求。
            let detail = text(body["description"]) ?? text(body["command"]) ?? text(body["tool"])
            guard let detail, !detail.isEmpty else { return [] }
            var payload: [String: Any] = ["message": detail]
            if let choices = body["choices"] as? [Any] {
                // 安全硬限：只接受一次性/拒绝。`always`/`session` 这类持久授权
                // 不能由一帧可伪造的 SSE 诱导用户点击授予——即使服务端下发了也过滤掉。
                let allowed: Set<String> = ["once", "deny", "reject", "cancel"]
                let usable = choices.compactMap { text($0) }
                    .filter { !$0.isEmpty && allowed.contains($0.lowercased()) }
                if !usable.isEmpty { payload["choices"] = usable }
            }
            if let requestID = text(body["request_id"]), !requestID.isEmpty {
                payload["request_id"] = requestID
            }
            if let command = text(body["command"]), !command.isEmpty, command != detail {
                payload["command"] = command
            }
            return emit("approval", payload, id: frame.id)

        case "clarify.request":
            // agent 执行到一半需要用户补充信息。与审批的区别：字段是 `question`
            // 不是 `description`，选项是任意文本不是 once/deny 白名单，而且
            // `execution_generation` 必须原样带回去——服务端 `respond_run` 拿它
            // 校验「答复的是不是当前这一代执行」，缺了直接 400。
            let question = text(body["question"]) ?? text(body["description"]) ?? text(body["message"])
            guard let question, !question.isEmpty else { return [] }
            var payload: [String: Any] = ["message": question, "question": question]
            if let choices = body["choices"] as? [Any] {
                // clarify 的选项是用户/模型给的任意文本，不做白名单过滤（那是审批的规则）。
                let usable = choices.compactMap { text($0) }.filter { !$0.isEmpty }
                if !usable.isEmpty { payload["choices"] = usable }
            }
            if let requestID = text(body["prompt_id"]), !requestID.isEmpty {
                payload["request_id"] = requestID
            }
            if let generation = body["execution_generation"] as? Int {
                payload["execution_generation"] = generation
            }
            if let multi = body["multi_select"] as? Bool {
                payload["multi_select"] = multi
            }
            return emit("clarify", payload, id: frame.id)

        case "clarify.settled":
            // 这条 clarify 已经结束（超时、被别处处理、或用户改用自由文本导致取消）。
            // 客户端必须据此收掉输入卡片，否则会留下一个点了没反应的框。
            var payload: [String: Any] = [:]
            if let requestID = text(body["prompt_id"]) { payload["request_id"] = requestID }
            return emit("clarify_resolved", payload, id: frame.id)

        case "approval.settled":
            // 审批也有一帧 settled（与 approval.responded 不同：后者是「自己答的」，
            // settled 覆盖超时/别处处理）。统一映射成同一个收卡片信号。
            var payload: [String: Any] = [:]
            if let requestID = text(body["request_id"]) ?? text(body["prompt_id"]) {
                payload["request_id"] = requestID
            }
            return emit("approval_resolved", payload, id: frame.id)

        case "error":
            let message = text(body["message"]) ?? text(body["error"]) ?? text(body["detail"]) ?? "Stream error"
            return emit("apperror", ["message": message], id: frame.id)

        case "run.started", "message.started", "done",
             "run.steered", "run.stopping":
            // 网关侧的生命周期帧，App 状态机没有对应语义（done 在 chat/stream 端只是收尾标记）。
            return []

        default:
            return []
        }
    }

    /// 网关 runs 端点把事件名放在 data JSON 的 `"event"` 字段，SSE 的 `event:` 行只是
    /// 兼容回退（WebUI chat/stream 用）。`map` 和 `GatewayBackend` 的 run 收尾判断都靠它。
    ///
    /// 与 `map` 保持同一套判定：JSON 与 SSE 行冲突时返回空串（不可信帧），
    /// 避免收尾逻辑被伪造帧单独驱动。
    static func rawEventName(of frame: SSEFrame) -> String {
        let jsonName = (object(from: frame.data)?["event"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sseName = frame.event.lowercased() == "message"
            ? nil : frame.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch (jsonName, sseName) {
        case let (json?, sse?):
            return json == sse ? json : ""
        case let (json?, nil):
            return json
        case let (nil, sse?):
            return sse
        case (nil, nil):
            return ""
        }
    }
}

// MARK: - run.completed

extension GatewayEventMap {

    /// 网关 `run.completed` 只给 `output` / `usage` / `partial` / `interrupted`，
    /// 而 App 的 `done` 分支会跑 `try ChatSnapshot(data:)`，要求
    /// `{"session_id": "...", "messages": [...]}`（或 `{"session": {...}}`）。
    /// 所以这里合成一个最小合法快照。
    fileprivate static func completed(_ body: [String: Any], id: String?) -> [SSEFrame] {
        let output = text(body["output"]) ?? text(body["text"]) ?? ""
        let partial = boolean(body["partial"]) ?? false
        let interrupted = boolean(body["interrupted"]) ?? false
        var usage: Any? = body["usage"]
        if usage is NSNull { usage = nil }

        if partial || interrupted {
            // 半截/被中断的轮次用 cancel 收尾，不用 done、也不用 stream_end：
            // 1. 不用 done：合成快照里没有 messages / tool_calls，走 done 会把这段流式内容
            //    整个替换成一条半截 assistant 消息，工具卡片和已渲染正文一起丢。
            // 2. 不用 stream_end：它只在 status 为 failed / error 时判失败，传 "interrupted"
            //    只会静默收尾，用户在界面上看不出「这轮被打断了」。
            // 3. cancel 既终止流（terminal = true），又保留已流式的内容，并给出可见提示。
            // 附带 `status` 只为日志/抓包可读，App 的 cancel 分支忽略载荷。
            var payload: [String: Any] = ["status": "interrupted"]
            payload["message"] = interrupted ? "interrupted" : "partial"
            if let usage { payload["usage"] = usage }
            return emit("cancel", payload, id: id)
        }

        // 预算/步数耗尽：网关用 `completed: false` 表示这轮其实没跑完。
        // 客户端不能把它当正常完成（用户会以为回复真的说完了），要留一条可见的
        // 「预算上限」通知行。用 stream_end 收尾，既终止流又保留已流式内容。
        //
        // 严格 Bool 语义：只认真正的布尔。缺省 / null / "unknown" / 2 / {} 等
        // 畸形值一律视为「状态未知」——既不当作正常完成，也不当作预算耗尽，
        // 而是给出 work_limit 之外的中性提示，避免伪造帧击穿这条判定。
        let completedFlag = body["completed"] as? Bool
        if completedFlag == false {
            var payload: [String: Any] = ["status": "work_limit"]
            if let usage { payload["usage"] = usage }
            return emit("stream_end", payload, id: id)
        }
        if completedFlag == nil {
            // 状态未知：收尾但不宣称「正常完成」，让 UI 显示中性提示。
            var payload: [String: Any] = ["status": "unknown"]
            if let usage { payload["usage"] = usage }
            return emit("stream_end", payload, id: id)
        }

        guard !output.isEmpty else {
            // 正常的空输出：不能合成快照——ChatSnapshot 会过滤掉空 content 的 assistant 行，
            // messages 变成 []，反而把已经流式渲染的正文清空。用 stream_end 正常收尾。
            var payload: [String: Any] = ["status": "completed"]
            if let usage { payload["usage"] = usage }
            return emit("stream_end", payload, id: id)
        }

        // 这里刻意**不**发 done。
        //
        // done 的语义是「用快照里的 messages 覆盖整个列表」，而网关的
        // run.completed 只给一段 output、拿不到真实消息行（没有 id、没有
        // sourceIndex）。合成出来的单条消息会把已加载的历史压成一条，随后
        // 那次 history 拉取再重建一遍——用户看到的是回复刚结束、历史闪一下，
        // 正在拖选的文字立刻被重建打断（表现为「选不过段」）。
        //
        // stream_end 只标记收尾、保留现有消息：流式累积的正文原样留在
        // buffer 里，紧接着的 history 拉取会用真实行替换。usage 照样带出去，
        // ChatTranscript 的 stream_end 分支会读。
        var payload: [String: Any] = ["status": "completed"]
        if let usage { payload["usage"] = usage }
        return emit("stream_end", payload, id: id)
    }
}

// MARK: - 会话身份回填

extension GatewayEventMap {

    /// 把 `done` 帧里的会话身份改写成真实 id。
    ///
    /// **现状（F-50）：生产路径已不再产生 `done` 帧。** `completed(_:id:)` 现在一律用
    /// `stream_end` 收尾（原因见那里的注释：`done` 会用快照覆盖整个消息列表）。
    /// 因此本函数在生产代码里没有调用点，仅保留给离线测试与将来可能恢复的
    /// `done` 通道——删除会让 `tests/gateway` 编译失败，所以刻意保留。
    ///
    /// 它解决的问题仍然成立：如果某条通道真的发出 `done`，而快照里的
    /// `session_id` 是 `run_id` 占位值，`ChatSnapshot` 会照单全收，随后
    /// `NativeChatModel` 一比就发现对不上，抛 `done session mismatch` 把整条流掐断
    /// ——症状是回复已经渲染完，然后弹一个错。只有知道 run 归属的 `GatewayBackend`
    /// 能补这个字段。
    ///
    /// 拿不到真实 id 时降级成 `stream_end`：已经流式渲染的正文留在 buffer 里，
    /// 随后那次 history 拉取会补齐真实窗口，用户看到的是正常收尾而不是报错。
    static func retarget(_ frame: SSEFrame, sessionID: String?) -> SSEFrame {
        guard frame.event == "done" else { return frame }
        guard let sessionID, !sessionID.isEmpty,
              var root = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8)))
                as? [String: Any] else {
            return SSEFrame(event: "stream_end", data: #"{"status":"completed"}"#, id: frame.id)
        }
        var session = (root["session"] as? [String: Any]) ?? [:]
        session["session_id"] = sessionID
        root["session"] = session
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8) else {
            return SSEFrame(event: "stream_end", data: #"{"status":"completed"}"#, id: frame.id)
        }
        return SSEFrame(event: "done", data: text, id: frame.id)
    }
}

// MARK: - 测试辅助

extension GatewayEventMap {

    /// 测试用：把输出帧的 data 解成字典。解析失败返回空字典（不抛错）。
    static func payload(of frame: SSEFrame) -> [String: Any] {
        object(from: frame.data) ?? [:]
    }
}

// MARK: - 解析与编码

private extension GatewayEventMap {

    /// 组装一帧 App 事件；id 必须原样继承，否则重连去重会失效。
    static func emit(_ event: String, _ payload: [String: Any], id: String?) -> [SSEFrame] {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else { return [] }
        return [SSEFrame(event: event, data: encoded, id: id)]
    }

    /// 只接受顶层 JSON 对象；数组、裸标量、坏 JSON 一律 nil。
    static func object(from data: String) -> [String: Any]? {
        guard let raw = data.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: raw),
              let object = root as? [String: Any] else { return nil }
        return object
    }

    /// 宽松取字符串：字符串原样，数字/布尔转文本，对象/数组转 JSON 文本，null 视为缺失。
    static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// 宽松取布尔：网关可能给 true/false、0/1、 "true"/"false"。
    static func boolean(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = value as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0", "": return false
        default: return nil
        }
    }

    static func toolName(_ body: [String: Any]) -> String? {
        for key in ["tool", "name"] {
            if let name = text(body[key]), !name.isEmpty { return name }
        }
        return nil
    }

    static func toolCallID(_ body: [String: Any]) -> String? {
        // tid 为空串会让 App 建出一条 id 为空的工具卡片，直接当缺失处理。
        for key in ["tool_call_id", "tid", "call_id"] {
            if let tid = text(body[key]), !tid.isEmpty { return tid }
        }
        return nil
    }
}
