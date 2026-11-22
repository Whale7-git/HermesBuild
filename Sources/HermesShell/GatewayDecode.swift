import Foundation
import CoreFoundation

/// 网关解码失败的原因。
///
/// 与 `ChatCoreError` 分开的理由：这类错误只说明「网关 JSON 和 App 模型对不上」，
/// 调用方应当提示并把旧数据留在屏幕上，而不是把它当成「服务器说会话没了」。
enum GatewayDecodeError: Error, LocalizedError, Equatable {
    /// 顶层不是 JSON 对象。
    case notObject(String)
    /// 必要的数组字段缺失或类型不对。
    case missingArray(String)
    /// 结构能读，但字段语义不成立（例如会话缺少 id）。
    case malformed(String)
    /// 消息响应里既没有顶层 `session_id`，行内也没有。
    case missingSessionID
    /// 网关返回了 `{"error": ...}`。
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notObject(let what): return "\(what)不是 JSON 对象"
        case .missingArray(let what): return "\(what)缺少数组字段"
        case .malformed(let detail): return "网关数据格式异常：\(detail)"
        case .missingSessionID: return "网关消息响应里没有 session_id"
        case .server(let detail): return detail
        }
    }
}

/// 网关（hermes-agent HTTP API）→ App 现有模型的唯一转换层。
///
/// 网关的字段名和 WebUI 不同（`id` / `last_active` / `started_at` vs
/// `session_id` / `updated_at` / `created_at`），所以会话列表不能直接
/// `decode([SessionSummary].self)`，必须逐字段映射；消息则重新组装成
/// `ChatSnapshot` 已经认识的形状，复用它原有的分页、去重和工具卡片逻辑。
enum GatewayDecode {

    // MARK: - 1) 会话列表

    /// `GET /api/sessions` → `[SessionSummary]`。
    ///
    /// 过滤 `is_internal_child == true`（子代理会话）与 `hidden == true`；
    /// `archived` 保留，是否折叠由调用方决定。
    /// 顶层不是对象、`data` 缺失或不是数组时抛错——静默返回空数组会让 UI
    /// 以为会话真的被删光了。
    static func sessions(_ data: Data) throws -> [SessionSummary] {
        try sessions(root: gatewayRoot(data, what: "会话列表"))
    }

    /// Reuse an already-decoded page in GatewaySessionReader; no second JSON
    /// deserialization on MainActor for every page of a large session list.
    static func sessions(root: [String: Any]) throws -> [SessionSummary] {
        if let error = root["error"], !(error is NSNull) {
            throw GatewayDecodeError.server(gatewayString(error) ?? "会话列表读取失败")
        }
        guard let list = root["data"] as? [Any] else {
            throw GatewayDecodeError.missingArray("会话列表 data")
        }

        var result: [SessionSummary] = []
        result.reserveCapacity(list.count)
        // 单条脏数据（缺 id / 非对象）只跳过，不让整份列表失败。
        for raw in list {
            guard let row = raw as? [String: Any] else { continue }
            guard let id = gatewayIdentifier(row["id"]) else { continue }
            if gatewayBool(row["is_internal_child"]) == true { continue }
            if gatewayBool(row["hidden"]) == true { continue }

            let startedAt = gatewayNumber(row["started_at"])
            result.append(SessionSummary(
                sessionId: id,
                title: gatewayString(row["title"]),
                // last_active 缺失时回落 started_at，UI 排序至少不会把老会话排到最后。
                updatedAt: gatewayNumber(row["last_active"]) ?? startedAt,
                createdAt: startedAt,
                messageCount: gatewayInt(row["message_count"]),
                // 网关不提供 profile / 工作目录 / 流式标记，宁可留 nil 也不猜。
                profile: nil,
                source: gatewayString(row["source"]),
                archived: gatewayBool(row["archived"]),
                pinned: gatewayBool(row["pinned"]),
                preview: gatewayString(row["preview"]),
                isStreaming: nil,
                model: gatewayString(row["model"]),
                workspace: nil))
        }
        return result
    }

    /// Decode the optional authoritative pending-control projection from
    /// GET /v1/runs/{id}. Missing means the Gateway does not expose this
    /// capability; an empty array means it explicitly reports no pending controls.
    static func pendingControlSnapshot(from root: [String: Any]) -> GatewayPendingControlSnapshot? {
        guard let raw = root["pending_controls"] else { return nil }
        guard let controls = raw as? [[String: Any]] else {
            return GatewayPendingControlSnapshot(frames: [], hasIncompleteControl: true)
        }

        func nonempty(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double >= 0,
                  double.rounded(.towardZero) == double,
                  let result = Int(exactly: number.int64Value),
                  Double(result) == double else { return nil }
            return result
        }

        var frames: [SSEFrame] = []
        var incomplete = false
        var seenPromptIDs = Set<String>()
        for control in controls {
            guard let kind = nonempty(control["kind"]),
                  let promptID = nonempty(control["prompt_id"]),
                  seenPromptIDs.insert(promptID).inserted,
                  let generation = integer(control["execution_generation"]) else {
                incomplete = true
                continue
            }

            var body: [String: Any]
            switch kind.lowercased() {
            case "approval":
                let detail = nonempty(control["description"])
                    ?? nonempty(control["command"]) ?? nonempty(control["tool"])
                let allowed: Set<String> = ["once", "deny", "reject", "cancel"]
                let choices = ((control["choices"] as? [Any])?.compactMap { $0 as? String } ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && allowed.contains($0.lowercased()) }
                // Do not let ChatPendingApproval's legacy once/deny fallback
                // invent a card when the server did not supply usable choices.
                guard let detail, !choices.isEmpty else {
                    incomplete = true
                    continue
                }
                body = [
                    "event": "approval.request",
                    "request_id": promptID,
                    "execution_generation": generation,
                    "description": detail,
                    "choices": choices
                ]
                if let command = nonempty(control["command"]) { body["command"] = command }
            case "clarify":
                let question = nonempty(control["question"])
                    ?? nonempty(control["description"]) ?? nonempty(control["message"])
                guard let question else {
                    incomplete = true
                    continue
                }
                let choices = ((control["choices"] as? [Any])?.compactMap { $0 as? String } ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                body = [
                    "event": "clarify.request",
                    "prompt_id": promptID,
                    "execution_generation": generation,
                    "question": question,
                    "choices": choices
                ]
                if let multi = control["multi_select"] as? Bool { body["multi_select"] = multi }
            default:
                incomplete = true
                continue
            }

            guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                incomplete = true
                continue
            }
            let mapped = GatewayEventMap.map(SSEFrame(event: "message", data: text, id: nil))
            guard mapped.count == 1 else {
                incomplete = true
                continue
            }
            frames.append(mapped[0])
        }
        return GatewayPendingControlSnapshot(frames: frames, hasIncompleteControl: incomplete)
    }

    // MARK: - 2) 会话消息 → ChatSnapshot

    /// `GET /api/sessions/{id}/messages?order=latest` → `ChatSnapshot`。
    ///
    /// 网关每行的 `id` 是整数，而 `stableMessageID` 只把字符串 id 当稳定标识；
    /// 这里统一转成字符串再放进 `messages[].id`，否则 App 的占位绑定
    /// （`knownIDs` 集合比对）会失效，用户会看到气泡重复或身份错乱。
    ///
    /// `offset` 是该窗口在原始历史里的起点，原样写进 `_messages_offset`，
    /// `ChatSnapshot` 据此算出每行稳定的 `sourceIndex`。
    static func snapshot(_ data: Data, offset: Int, activeRunID: String? = nil,
                         requestedSessionID: String? = nil,
                         runStatusUnknown: Bool = false,
                         pendingControls: GatewayPendingControlSnapshot? = nil) throws -> ChatSnapshot {
        let root = try gatewayRoot(data, what: "会话消息")
        if let error = root["error"], !(error is NSNull) {
            throw GatewayDecodeError.server(gatewayString(error) ?? "会话消息读取失败")
        }
        guard let list = root["data"] as? [Any] else {
            throw GatewayDecodeError.missingArray("会话消息 data")
        }
        let offset = max(0, offset)
        var sessionID = gatewayIdentifier(root["session_id"])

        var rows: [[String: Any]] = []
        rows.reserveCapacity(list.count)
        // 单条坏行（缺 role、不是对象）只跳过，不能让整份历史读取失败。
        //
        // F-68：工具结果行有时只带 tool_name 不带 tool_call_id；原来按工具名全局
        // FIFO 认领，同名工具跨轮次时会挂到更早那一轮的 callID 上（结果串轮）。
        // 现在按 assistant 行分组：每遇到一条新的 assistant 行就重置 pending 队列，
        // 只在本行内 FIFO，保证认领的一定是本轮发出的调用。
        //
        // 代价是「结果行晚于下一条 assistant 行到达」时不再回溯认领——那种情况宁可
        // 多出一张独立结果卡，也不能把结果挂到别的轮次上。窗口从中间截断时开头的
        // tool 行同样没有可认领的队列（空队列即不认领），符合这个取舍。
        //
        // F-68 残差：按轮分组之后，**同一轮内两个同名工具**仍然有歧义——结果行缺
        // `tool_call_id` 时 FIFO 会把它挂到先发起的那个调用上，看起来像成功关联，
        // 实际可能挂错。所以这里额外记录「本轮每个工具名发起了几次调用」：
        // 同名调用数 > 1 时，缺 id 的结果行一律**不认领**，单独成一张卡并把名字
        // 标成「（未能关联）」，让 UI 能看出这条结果没对上调用。
        // 取舍：宁可多一张卡（用户看到一条孤立结果），也不挂到错误的那次调用上
        // ——错配会让参数和结果张冠李戴，比多一张卡难排查得多。
        var pendingCalls: [String: [String]] = [:]
        // 本轮每个工具名已发起的调用次数（与 `pendingCalls` 同步重置）。
        var issuedCallCounts: [String: Int] = [:]

        for raw in list {
            guard let row = raw as? [String: Any] else { continue }
            if sessionID == nil { sessionID = gatewayIdentifier(row["session_id"]) }

            // 网关里 assistant / user / tool 之外的 session_meta 等控制行，
            // 不在这里删除：ChatSnapshot 自己的 role 过滤已经把它们排除在
            // messages 之外，而保留原行才能让 _messages_offset / sourceIndex
            // 与网关的原始行序对齐——分页 offset 和分支的 keepCount 都按原始
            // 行号算，少一行就会错位。
            // display_kind == internal_notification 是真实的用户消息，只是
            // 标记了来源，必须保留。
            let role = gatewayString(row["role"])?.lowercased() ?? ""
            // 缺 role 的行无法安全定位历史坐标，跳过而不是让整份历史失败。
            guard !role.isEmpty else { continue }

            var out: [String: Any] = ["role": role]
            if let messageID = gatewayIdentifier(row["id"]) ?? gatewayIdentifier(row["message_id"]) {
                out["id"] = messageID
            }
            if let content = row["content"], !(content is NSNull) { out["content"] = content }
            if let timestamp = gatewayNumber(row["timestamp"]) { out["timestamp"] = timestamp }
            if let attachments = row["attachments"], !(attachments is NSNull) {
                out["attachments"] = attachments
            }
            if let kind = gatewayString(row["display_kind"]) { out["display_kind"] = kind }

            // 任何一条新的 assistant 行都意味着新一轮开始：先清空上一轮没被认领完
            // 的调用，避免同名工具的结果挂到上一轮的 callID 上（F-68）。
            // 放在 tool_calls 判断之外，纯文本 assistant 行同样要切断队列。
            if role == "assistant" {
                pendingCalls.removeAll(keepingCapacity: true)
                issuedCallCounts.removeAll(keepingCapacity: true)
            }

            if role == "assistant", let calls = row["tool_calls"] as? [Any], !calls.isEmpty {
                let rowKey = out["id"] as? String ?? "\(offset + rows.count)"
                var normalized: [[String: Any]] = []
                normalized.reserveCapacity(calls.count)
                for (callIndex, rawCall) in calls.enumerated() {
                    guard let call = rawCall as? [String: Any] else { continue }
                    // 网关两种形态都要吃下：OpenAI 的 {id, function:{name,arguments}}
                    // 和已归一化的 {name, args}。
                    let function = call["function"] as? [String: Any] ?? [:]
                    let name = gatewayString(function["name"])
                        ?? gatewayString(call["name"]) ?? "Tool"
                    let args = gatewayArguments(function["arguments"] ?? call["args"])
                    // 没有 id 时造一个与分页无关的稳定 id（行 id + 序号）。
                    let callID = gatewayIdentifier(call["id"])
                        ?? gatewayIdentifier(call["tool_call_id"])
                        ?? gatewayIdentifier(call["tid"])
                        ?? "\(rowKey):call:\(callIndex)"
                    normalized.append([
                        "id": callID,
                        "tid": callID,
                        "name": name,
                        "args": args,
                        "function": ["name": name, "arguments": args]
                    ])
                    pendingCalls[name, default: []].append(callID)
                    issuedCallCounts[name, default: 0] += 1
                }
                if !normalized.isEmpty { out["tool_calls"] = normalized }
            }

            if role == "tool" {
                let name = gatewayString(row["tool_name"]) ?? gatewayString(row["name"])
                var callID = gatewayIdentifier(row["tool_call_id"]) ?? gatewayIdentifier(row["tid"])
                // 只在结果行**缺 `tool_call_id`** 时才用名字兜底匹配（F-68）。
                // 有 id 就无条件信 id：那是服务端给的权威关联，不需要猜。
                var unlinked = false
                if let explicitID = callID, let name {
                    // 这条结果已经用权威 id 认领过了，必须把它从名字队列里摘掉：
                    // 否则同轮后面那条缺 id 的结果行还会按名字 FIFO 认领到同一个
                    // callID，等于两条结果抢一张卡（第二次认领是错的）。
                    pendingCalls[name]?.removeAll { $0 == explicitID }
                }
                if callID == nil, let name {
                    if issuedCallCounts[name, default: 0] > 1 {
                        // 同一轮内这个工具名发起了不止一次调用，缺 id 时无法判断
                        // 这条结果是哪一次的。不认领，让它单独成卡（F-68）。
                        unlinked = true
                    } else if var queue = pendingCalls[name], !queue.isEmpty {
                        callID = queue.removeFirst()
                        pendingCalls[name] = queue
                    }
                }
                if let callID {
                    out["tool_call_id"] = callID
                    out["tid"] = callID
                }
                if let name {
                    // 「未能关联」只标在**有歧义**的那种结果上：卡片仍然展示结果，
                    // 但名字带后缀，一眼能看出这条结果没对上调用，而不是被静默
                    // 挂到错误的调用上（错配会让参数和结果张冠李戴）。
                    out["name"] = unlinked ? "\(name)（未能关联）" : name
                }
                if let result = row["result"], !(result is NSNull) { out["result"] = result }
                if let isError = row["is_error"] as? Bool { out["is_error"] = isError }
            }

            rows.append(out)
        }


        guard let sessionID, !sessionID.isEmpty else {
            throw GatewayDecodeError.missingSessionID
        }

        // 服务端返回的 session_id 与请求不一致时必须报错，而不是静默用请求值覆盖：
        // 覆盖会让 applySnapshot 的归属校验永远成立，串会话时客户端毫无感知，
        // 错误消息还会写进磁盘缓存。
        if let requestedSessionID, !requestedSessionID.isEmpty,
           requestedSessionID != sessionID {
            throw GatewayDecodeError.malformed(
                "会话身份不一致：请求 \(requestedSessionID)，服务端返回 \(sessionID)")
        }

        var session: [String: Any] = [
            "session_id": sessionID,
            "_messages_offset": offset,
            "messages": rows,
            // 网关把调用挂在 assistant 行的 tool_calls 上，没有独立列表；
            // 显式给空数组，免得 ChatSnapshot 认为字段类型不对。
            "tool_calls": [] as [Any]
        ]
        if let active = activeRunID ?? gatewayIdentifier(root["active_stream_id"])
            ?? gatewayIdentifier(root["active_run_id"]) {
            session["active_stream_id"] = active
        }
        if let model = gatewayString(root["model"]), !model.isEmpty { session["model"] = model }
        if let provider = gatewayString(root["model_provider"]), !provider.isEmpty {
            session["model_provider"] = provider
        }

        let assembled = try JSONSerialization.data(withJSONObject: ["session": session])
        return try ChatSnapshot(data: assembled, runStatusUnknown: runStatusUnknown,
                                gatewayPendingControls: pendingControls)
    }

    // MARK: - 3) 模型目录占位判定

    /// 网关自报的模型目录是不是「占位」：只有一个 hermes-agent 条目。
    ///
    /// `/v1/models` 对网关只是个占位，真实目录要去配套 WebUI 取。畸形响应
    /// （非对象 / 没有 data 数组）也判为占位——这时候回落总比拿占位当真目录好。
    ///
    /// **现状（F-50）：生产代码已不再调用。** 模型目录改走 `/api/model/options`
    /// + `GatewayModelCatalog.hasUsableModels`（后者能识别「provider 全空」这种
    /// 占位之外的失效形态，覆盖面更广），`/v1/models` 这条路径不再使用。
    /// 本函数仅被 `tests/gateway` 引用，删掉会让测试编译失败，因此保留；
    /// 若将来确认测试也不再需要，可整体移除。
    static func isPlaceholderModelCatalog(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [Any] else {
            return true
        }
        guard list.count == 1,
              let entry = list.first as? [String: Any],
              let id = gatewayString(entry["id"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        return id.lowercased() == "hermes-agent"
    }
}

// MARK: - 宽松取值

/// 顶层必须是对象；非法 JSON 也归一成可读错误，而不是把 DecodingError 漏给 UI。
private func gatewayRoot(_ data: Data, what: String) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
        throw GatewayDecodeError.malformed("\(what)不是合法 JSON")
    }
    guard let root = object as? [String: Any] else {
        throw GatewayDecodeError.notObject(what)
    }
    return root
}

/// 字符串字段；数字 id 之类也顺手转一下，缺省一律 nil。
private func gatewayString(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

/// 消息/会话标识位：整数 id 必须变成不带小数点的字符串。
private func gatewayIdentifier(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber {
        let double = number.doubleValue
        if double.isFinite, double.rounded() == double, double.magnitude < 9.2e18 {
            return String(number.int64Value)
        }
        return number.stringValue
    }
    return nil
}

private func gatewayNumber(_ value: Any?) -> Double? {
    guard let value, !(value is NSNull) else { return nil }
    if let double = value as? Double { return double.isFinite ? double : nil }
    if let number = value as? NSNumber {
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
    if let text = value as? String, let double = Double(text) { return double.isFinite ? double : nil }
    return nil
}

/// 业务上界 1e15：超过这个量级的计数当没报，免得后续 Int 转换 trap。
private func gatewayInt(_ value: Any?) -> Int? {
    guard let double = gatewayNumber(value), double.magnitude <= 1_000_000_000_000_000 else { return nil }
    return Int(double)
}

private func gatewayBool(_ value: Any?) -> Bool? {
    guard let value, !(value is NSNull) else { return nil }
    if let flag = value as? Bool { return flag }
    if let text = value as? String {
        switch text.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
    if let number = value as? NSNumber { return number.intValue != 0 }
    return nil
}

/// 工具参数：字符串原样用，对象/数组序列化成 JSON 文本，交给 `displayValue` 显示。
private func gatewayArguments(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let text = value as? String { return text }
    guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                 options: [.sortedKeys, .fragmentsAllowed]),
          let text = String(data: data, encoding: .utf8) else { return "" }
    return text
}
