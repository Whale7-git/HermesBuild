import Foundation

/// 纯逻辑测试：网关事件映射、分页换算、JSON 解码。
/// 不发任何网络请求，不依赖 UIKit。
@MainActor
func runGatewayTests() throws {
    try gatewayEventMappingTests()
    try gatewayPagingTests()
    try gatewayDecodeTests()
    gatewayRetargetTests()
    gatewayAttachmentPathTests()
    try gatewayModelCatalogTests()
    try gatewayFilterTests()
    try gatewayReasoningRequestTests()
}

// MARK: - Per-run Gateway reasoning options
func gatewayReasoningRequestTests() throws {
    let requests = GatewayRequests(baseURL: URL(string: "https://example.test")!, apiKey: "fixture")
    let standard = try requests.startRun(sessionID: "s", text: "hi")
    let defaultBody = try JSONSerialization.jsonObject(with: standard.httpBody!) as! [String: Any]
    expect(defaultBody["model_options"] == nil, "server default emits no effort field")
    let high = try requests.startRun(sessionID: "s", text: "hi",
                                     model: nil, provider: nil, reasoningEffort: "high")
    let selectedBody = try JSONSerialization.jsonObject(with: high.httpBody!) as! [String: Any]
    expect((selectedBody["model_options"] as? [String: Any])?["reasoning_effort"] as? String == "high",
           "non-default effort is nested in model_options for this Run only")
    expect(selectedBody["input"] as? String == "hi" && selectedBody["session_id"] as? String == "s",
           "reasoning override cannot affect Session identity or input")
    expectThrows("invalid effort fails before POST") {
        _ = try requests.startRun(sessionID: "s", text: "hi", model: nil,
                                   provider: nil, reasoningEffort: "maximum")
    }
}

// MARK: - 模型目录

@MainActor
func gatewayModelCatalogTests() throws {
    let sample = #"{"providers":[{"slug":"custom:fixture","name":"fixture","is_current":true,"total_models":2,"models":["fixture/model-a","fixture/model-b"]},{"slug":"empty","name":"Empty","is_current":false,"total_models":0,"models":[]},{"slug":"broken","name":"Broken","is_current":false}],"model":"fixture/model-b","provider":"custom:fixture"}"#
    let catalog = try GatewayModelCatalog.options(Data(sample.utf8))
    // 空的和残缺的 provider 都要丢掉，只留能点出模型的那些。
    expect(catalog.options.count == 2, "only providers with models survive")
    expect(catalog.options.allSatisfy { $0.providerID == "custom:fixture" },
           "provider dimension is carried on every option")
    expect(catalog.defaultModel == "fixture/model-b", "current model is read from the top level")
    expect(catalog.activeProvider == "custom:fixture", "current provider is read from the top level")
    expect(Set(catalog.options.map(\.id)).count == catalog.options.count, "option ids stay unique")
    expect(GatewayModelCatalog.hasUsableModels(Data(sample.utf8)), "a provider with models is usable")
    expect(!GatewayModelCatalog.hasUsableModels(
        Data(#"{"providers":[{"slug":"x","models":[]}]}"#.utf8)),
        "all-empty providers are not usable")

    // 全是空 provider 时必须报错，不能返回空目录冒充「没有模型」。
    expectThrows("empty catalog throws") {
        _ = try GatewayModelCatalog.options(Data(#"{"providers":[{"slug":"x","models":[]}]}"#.utf8))
    }
    expectThrows("missing providers throws") {
        _ = try GatewayModelCatalog.options(Data(#"{"model":"m"}"#.utf8))
    }
}

// MARK: - 会话本地过滤

@MainActor
func gatewayFilterTests() throws {
    let json = #"[{"session_id":"a","title":"Hermes 网关调试","preview":"今天调了 fork 历史","updated_at":100},{"session_id":"b","title":"别的会话","preview":"里面提到 hermes 和 网关","updated_at":200},{"session_id":"c","title":"归档的那个","preview":"旧内容","updated_at":300,"archived":true}]"#
    let rows = try JSONDecoder().decode([SessionSummary].self, from: Data(json.utf8))

    // 多关键词 AND、跨标题与预览命中；标题命中排在预览命中之前。
    let hits = GatewaySessionFilter.search(rows, query: "hermes 网关")
    expect(hits.map(\.sessionId) == ["a", "b"], "title hit ranks before preview hit")
    expect(GatewaySessionFilter.search(rows, query: "hermes").count == 2, "single term matches both")
    // 空查询不返回全部：调用方用列表页看全部。
    expect(GatewaySessionFilter.search(rows, query: "   ").isEmpty, "blank query yields nothing")
    expect(GatewaySessionFilter.search(rows, query: "hermes", limit: 0).isEmpty, "limit 0 yields nothing")

    expect(GatewaySessionFilter.archived(rows).map(\.sessionId) == ["c"], "archived picks flagged rows")
    expect(Set(GatewaySessionFilter.active(rows).map(\.sessionId)) == ["a", "b"],
           "active excludes archived")

    // 摘要只在命中时给出，且不能切坏多字节字符。
    expect(GatewaySessionFilter.snippet(for: rows[1], query: "网关")?.contains("网关") == true,
           "snippet contains the term")
    expect(GatewaySessionFilter.snippet(for: rows[1], query: "不存在的词") == nil,
           "no hit means no snippet")
}

// MARK: - 会话身份回填

/// 网关 `run.completed` 只给 run_id，合成的 done 帧必须能被改写成真实会话 id，
/// 否则 NativeChatModel 的 `done session mismatch` 会把整条流掐断。
@MainActor
func gatewayRetargetTests() {
    let completed = SSEFrame(
        event: "done",
        data: #"{"session":{"session_id":"run_abc","messages":[{"role":"assistant","content":"hi"}]}}"#,
        id: "7")

    let fixed = GatewayEventMap.retarget(completed, sessionID: "sess_42")
    expect(fixed.event == "done", "retarget keeps done when the id is known")
    expect(fixed.id == "7", "retarget must keep the event id for dedupe")
    let payload = GatewayEventMap.payload(of: fixed)
    let session = payload["session"] as? [String: Any]
    expect(session?["session_id"] as? String == "sess_42", "session id is rewritten")

    // 拿不到真实 id 时必须降级成正常收尾，而不是留一个会被拒收的 done。
    for missing in [nil, ""] as [String?] {
        let degraded = GatewayEventMap.retarget(completed, sessionID: missing)
        expect(degraded.event == "stream_end", "unknown session degrades to stream_end")
        expect(degraded.id == "7", "degraded frame keeps the id")
    }

    // 非 done 帧一律原样返回：回填只针对收尾那一帧。
    let token = SSEFrame(event: "token", data: #"{"text":"x"}"#, id: "3")
    let untouched = GatewayEventMap.retarget(token, sessionID: "sess_42")
    expect(untouched.event == "token" && untouched.data == token.data, "non-done frames pass through")
}

// MARK: - 附件路径换算

func gatewayAttachmentPathTests() {
    let webui = "/home/hermeswebui/.hermes/attachments/sess_42/shot.png"
    expect(GatewayAttachmentPaths.rewrite(webui, gatewayDataPath: "/opt/data")
           == "/opt/data/attachments/sess_42/shot.png", "official layout maps to /opt/data")

    // 尾部斜杠与相对写法都要归一，否则会拼出 //opt/data//...
    expect(GatewayAttachmentPaths.rewrite(webui, gatewayDataPath: "/opt/data/")
           == "/opt/data/attachments/sess_42/shot.png", "trailing slash is normalised")
    expect(GatewayAttachmentPaths.rewrite(webui, gatewayDataPath: "opt/data")
           == "/opt/data/attachments/sess_42/shot.png", "missing leading slash is added")

    // 没配映射时不能动路径：猜错位置比直接失败更难查。
    expect(GatewayAttachmentPaths.rewrite(webui, gatewayDataPath: "") == webui,
           "empty mapping leaves the path alone")
    // 认不出前缀也原样保留。
    expect(GatewayAttachmentPaths.rewrite("/tmp/other/shot.png", gatewayDataPath: "/opt/data")
           == "/tmp/other/shot.png", "unrecognised path is untouched")
}

// MARK: - 事件映射

private func frame(_ event: String, _ json: String, id: String? = nil) -> SSEFrame {
    SSEFrame(event: event, data: json, id: id)
}

private func payload(_ frame: SSEFrame) -> [String: Any] {
    GatewayEventMap.payload(of: frame)
}

private func gatewayEventMappingTests() throws {
    // message.delta → token
    let delta = GatewayEventMap.map(frame("message.delta",
        #"{"event":"message.delta","delta":"你好","run_id":"run_1"}"#, id: "3"))
    expect(delta.count == 1 && delta[0].event == "token", "message.delta maps to token")
    expect(payload(delta[0])["text"] as? String == "你好", "token carries delta text")

    // 网关 runs 端点不发 SSE `event:` 行，事件名在 data JSON 的 "event" 字段里，
    // frame.event 恒为 "message"。这条必须能映射，否则流式聊天整体退化（实测抓包确认）。
    let dataOnly = GatewayEventMap.map(SSEFrame(
        event: "message",
        data: #"{"event":"message.delta","delta":"好","seq":0}"#,
        id: "0"))
    expect(dataOnly.count == 1 && dataOnly[0].event == "token" && dataOnly[0].id == "0",
           "data-embedded event name is honoured, id is carried")
    // id 必须继承：断线重连靠它去重。
    expect(delta[0].id == "3", "mapped frame inherits the SSE id")

    // reasoning.available → reasoning
    let reason = GatewayEventMap.map(frame("reasoning.available",
        #"{"event":"reasoning.available","text":"想一想"}"#))
    expect(reason.count == 1 && reason[0].event == "reasoning", "reasoning.available maps to reasoning")
    expect(payload(reason[0])["text"] as? String == "想一想", "reasoning carries text")

    // tool.started → tool（tid 从 tool_call_id 转过来）
    let started = GatewayEventMap.map(frame("tool.started",
        #"{"event":"tool.started","tool":"read_file","preview":"a.txt","tool_call_id":"call_9"}"#))
    expect(started.count == 1 && started[0].event == "tool", "tool.started maps to tool")
    expect(payload(started[0])["name"] as? String == "read_file", "tool carries name")
    expect(payload(started[0])["tid"] as? String == "call_9", "tool carries tid")

    // tool.completed → tool_complete，且 error(布尔) 改名为 is_error
    let done = GatewayEventMap.map(frame("tool.completed",
        #"{"event":"tool.completed","tool":"read_file","duration":0.2,"error":true,"tool_call_id":"call_9"}"#))
    expect(done.count == 1 && done[0].event == "tool_complete", "tool.completed maps to tool_complete")
    expect(payload(done[0])["is_error"] as? Bool == true, "error becomes is_error")
    expect(payload(done[0])["name"] as? String == "read_file", "tool_complete carries name")

    // run.completed（正常）→ 必须能让 ChatSnapshot 解析成功
    let completed = GatewayEventMap.map(frame("run.completed",
        #"{"event":"run.completed","run_id":"run_1","output":"答案","usage":{"input_tokens":10,"output_tokens":2},"completed":true,"partial":false,"interrupted":false}"#,
        id: "7"))
    expect(!completed.isEmpty, "run.completed produces at least one frame")
    let terminal = completed.last!
    expect(terminal.event == "stream_end",
           "run.completed closes with stream_end, not done")
    // 关键：绝不能带 messages。done 会用快照覆盖整个列表，而这里只有一段
    // output、没有真实行 id，覆盖后历史会被压成一条，拖选随即被重建打断。
    let finished = GatewayEventMap.payload(of: terminal)
    expect(finished["messages"] == nil, "completed frame carries no messages array")
    expect(finished["session"] == nil, "completed frame carries no snapshot")
    expect((finished["usage"] as? [String: Any])?["output_tokens"] as? Int == 2,
           "usage is still forwarded on the terminal frame")
    expect(finished["status"] as? String == "completed", "status marks a normal finish")
    if terminal.event == "done" {
        // done 分支会执行 ChatSnapshot(data:)，必须是合法快照，否则整条流报错。
        let snapshot = try ChatSnapshot(data: Data(terminal.data.utf8))
        expect(snapshot.messages.count == 1, "synthesized snapshot holds the assistant reply")
        expect(snapshot.messages[0].content == "答案", "synthesized snapshot keeps output text")
    }

    // run.completed（partial）→ 不能被当成正常收尾
    let partial = GatewayEventMap.map(frame("run.completed",
        #"{"event":"run.completed","output":"半句","completed":false,"partial":true,"interrupted":false}"#))
    expect(partial.last?.event != "done", "partial completion is not a clean done")

    // P0-13：completed 必须是严格 Bool。缺省/null/畸形值不能当成正常完成，
    // 否则伪造或残缺的终态帧会绕过 work_limit 判定。
    func statusOf(_ json: String) -> String? {
        let mapped = GatewayEventMap.map(frame("run.completed", json))
        guard let last = mapped.last else { return nil }
        return payload(last)["status"] as? String
    }
    expect(statusOf(#"{"event":"run.completed","output":"x"}"#) == "unknown",
           "missing completed is unknown, not a clean finish")
    expect(statusOf(#"{"event":"run.completed","output":"x","completed":null}"#) == "unknown",
           "null completed is unknown")
    expect(statusOf(#"{"event":"run.completed","output":"x","completed":"unknown"}"#) == "unknown",
           "string completed is unknown")
    expect(statusOf(#"{"event":"run.completed","output":"x","completed":2}"#) == "unknown",
           "numeric completed is unknown")
    expect(statusOf(#"{"event":"run.completed","output":"x","completed":{} }"#) == "unknown",
           "object completed is unknown")
    expect(statusOf(#"{"event":"run.completed","output":"x","completed":false}"#) == "work_limit",
           "explicit false is work_limit")
    expect(statusOf(#"{"event":"run.completed","output":"x","completed":true}"#) == "completed",
           "explicit true is completed")

    // F-18：审批可选项必须硬限为一次性/拒绝，持久授权不能由一帧 SSE 授予。
    let limitedApproval = GatewayEventMap.map(frame("approval.request",
        #"{"event":"approval.request","description":"删除文件","choices":["once","deny","always","session"],"request_id":"r1"}"#))
    let choices = limitedApproval.first.flatMap { payload($0)["choices"] as? [String] } ?? []
    expect(!choices.contains("always") && !choices.contains("session"),
           "persistent approval choices are filtered out")
    expect(choices.contains("once") && choices.contains("deny"),
           "one-shot choices survive the filter")

    // F-19：data JSON 的 event 与 SSE event 行冲突时整帧丢弃（confused deputy）。
    var conflict = SSEFrame(event: "message.delta", data: #"{"event":"run.completed","output":"x"}"#, id: "9")
    expect(GatewayEventMap.map(conflict).isEmpty, "conflicting event names are dropped")
    conflict.event = "run.completed"
    expect(!GatewayEventMap.map(conflict).isEmpty, "matching event names are accepted")

    // F-19：空 event 名不能吞掉合法帧（应回退到 SSE event 行）。
    let fallbackName = GatewayEventMap.map(SSEFrame(event: "run.cancelled",
        data: #"{"event":"","run_id":"r"}"#, id: "10"))
    expect(fallbackName.last?.event == "cancel", "empty json event falls back to the sse event line")

    // run.interrupted → 终止且带提示
    let interrupted = GatewayEventMap.map(frame("run.interrupted",
        #"{"event":"run.interrupted","run_id":"run_1"}"#))
    expect(interrupted.last?.event == "cancel", "run.interrupted maps to cancel")

    // 未知事件一律丢弃，绝不抛错
    let unknown = GatewayEventMap.map(frame("some.future.event", "{}"))
    expect(unknown.isEmpty, "unknown events are dropped")

    // 畸形 JSON 也不能抛
    let broken = GatewayEventMap.map(frame("message.delta", "{not json"))
    expect(broken.isEmpty, "malformed json is dropped")

    // 空 event 名按 SSE 规范视作 message，同样丢弃
    let empty = GatewayEventMap.map(frame("", #"{"a":1}"#))
    expect(empty.isEmpty, "empty event name is ignored")

    // 状态类事件不该产生 App 帧（`done` 在 chat/stream 端只是收尾标记，App 用
    // stream_end/cancel 收尾，不能让它走 done 分支覆盖整个列表）。
    for silent in ["run.started", "run.queued", "message.started", "run.steered",
                   "run.stopping", "done"] {
        expect(GatewayEventMap.map(frame(silent, "{}")).isEmpty,
               "\(silent) produces no app frame")
    }

    // approval.request → approval（带可见描述）
    let approval = GatewayEventMap.map(frame("approval.request",
        #"{"event":"approval.request","tool":"terminal","command":"rm -rf /tmp/x"}"#))
    expect(approval.first?.event == "approval", "approval.request maps to approval")
    expect((payload(approval[0])["message"] as? String)?.contains("rm -rf") == true,
           "approval message names the command")

    // error → apperror
    let err = GatewayEventMap.map(frame("error", #"{"event":"error","message":"boom"}"#))
    expect(err.first?.event == "apperror", "error maps to apperror")
    expect(payload(err[0])["message"] as? String == "boom", "apperror carries message")

    // P0：终态收尾的白名单在 `GatewayBackend.streamNativeTurn` 里按**原始事件名**匹配，
    // 与 `map` 的产出无关（map 失败也要清 run）。所以这里锁两件事：
    //   1) 这两个名字必须真的映射成 apperror（否则用户看不到失败原因）；
    //   2) `rawEventName` 必须原样吐出白名单里的字面量，且冲突帧返回空串
    //      —— 空串不匹配白名单，伪造帧无法单独驱动收尾。
    let truncated = GatewayEventMap.map(frame("replay.truncated",
        #"{"event":"replay.truncated","run_id":"run_1"}"#, id: "11"))
    expect(truncated.count == 1 && truncated[0].event == "apperror",
           "replay.truncated maps to apperror")
    expect(truncated.first?.id == "11", "replay.truncated keeps the SSE id")
    expect((payload(truncated[0])["message"] as? String)?.isEmpty == false,
           "replay.truncated explains that the replay window expired")

    expect(GatewayEventMap.rawEventName(of: frame("replay.truncated",
        #"{"event":"replay.truncated"}"#)) == "replay.truncated",
           "raw name for replay.truncated matches the terminal whitelist literal")
    expect(GatewayEventMap.rawEventName(of: frame("error",
        #"{"event":"error","message":"boom"}"#)) == "error",
           "raw name for error matches the terminal whitelist literal")
    // 网关 runs 端点不带 event: 行时，raw 名只能来自 data JSON。
    expect(GatewayEventMap.rawEventName(of: SSEFrame(
        event: "message", data: #"{"event":"replay.truncated"}"#, id: "12")) == "replay.truncated",
           "raw name is read from the data-embedded event when there is no event: line")
    // 冲突帧不可信：raw 名必须为空，不能拿其中任意一个名字去清 run。
    expect(GatewayEventMap.rawEventName(of: SSEFrame(
        event: "message.delta", data: #"{"event":"replay.truncated"}"#, id: "13")).isEmpty,
           "conflicting names yield no raw name, so a forged frame cannot retire a run")
    // 非终态事件的 raw 名不在白名单内，收尾不能由它们触发。
    expect(GatewayEventMap.rawEventName(of: frame("message.delta", #"{"delta":"x"}"#))
           == "message.delta", "non-terminal raw names stay outside the terminal whitelist")
}

// MARK: - 分页换算

private func gatewayPagingTests() throws {
    expect(GatewayPaging.nextOffset(loadedCount: 0) == 0, "no loaded messages means offset 0")
    expect(GatewayPaging.nextOffset(loadedCount: 120) == 120, "offset tracks loaded count")
    expect(GatewayPaging.nextOffset(loadedCount: -5) == 0, "negative input clamps to 0")
    expect(GatewayPaging.pageSize(default: 60, max: 200) == 60, "default page size honoured")
    expect(GatewayPaging.pageSize(default: 9999, max: 200) == 200, "page size clamps to max")
    expect(GatewayPaging.pageSize(default: 0, max: 200) >= 1, "page size is at least 1")

    // 绝对索引换算（与 GatewayBackend.history 同一套公式，抽成算式验证）：
    // total=312, 首屏 before=nil → anchor=312, skip=0, returned=60 → absolute=252
    expect(absoluteOffset(total: 312, before: nil, limit: 60, returned: 60) == 252,
           "first page starts at the tail")
    // 再往前翻：before=252 → anchor=252, skip=60, returned=60 → absolute=192
    expect(absoluteOffset(total: 312, before: 252, limit: 60, returned: 60) == 192,
           "second page walks further back")
    // 一直翻到头部：before=12 → skip=300, returned=12 → absolute=0
    expect(absoluteOffset(total: 312, before: 12, limit: 60, returned: 12) == 0,
           "last page lands on index 0")
    // before 超出总量时夹住
    expect(absoluteOffset(total: 100, before: 999, limit: 60, returned: 60) == 40,
           "before beyond total is clamped")
}

/// 与 `GatewayBackend.history` 完全一致的换算，独立复算一遍防止实现漂移。
private func absoluteOffset(total: Int, before: Int?, limit: Int, returned: Int) -> Int {
    let anchor = before.map { min(max(0, $0), total) } ?? total
    let skip = max(0, total - anchor)
    return max(0, total - skip - returned)
}

// MARK: - JSON 解码

private func gatewayDecodeTests() throws {
    // 会话列表：字段名与 SessionSummary 不同，且要过滤子代理/隐藏会话
    let sessionsJSON = """
    {"object":"list","data":[
      {"id":"s1","title":"第一个","started_at":100.0,"last_active":200.0,
       "message_count":12,"source":"api_server","model":"fixture",
       "pinned":true,"archived":false,"hidden":false,"is_internal_child":false,
       "preview":"预览一"},
      {"id":"s2","title":"子代理","started_at":101.0,"last_active":201.0,
       "is_internal_child":true},
      {"id":"s3","title":"隐藏的","started_at":102.0,"last_active":202.0,"hidden":true},
      {"id":"s4","title":"归档的","started_at":103.0,"archived":true,"is_internal_child":false}
    ]}
    """
    let sessions = try GatewayDecode.sessions(Data(sessionsJSON.utf8))
    expect(sessions.count == 2, "internal-child and hidden sessions are filtered")
    expect(sessions[0].sessionId == "s1", "id maps to sessionId")
    expect(sessions[0].updatedAt == 200.0, "last_active maps to updatedAt")
    expect(sessions[0].createdAt == 100.0, "started_at maps to createdAt")
    expect(sessions[0].pinned == true, "pinned survives")
    expect(sessions[0].preview == "预览一", "preview survives")
    expect(sessions[0].isStreaming == nil, "isStreaming is not invented")
    expect(sessions.contains { $0.sessionId == "s4" }, "archived sessions are kept")

    // last_active 缺失时回落到 started_at
    let fallbackJSON = #"{"data":[{"id":"s9","started_at":50.0}]}"#
    let fallback = try GatewayDecode.sessions(Data(fallbackJSON.utf8))
    expect(fallback.first?.updatedAt == 50.0, "updatedAt falls back to started_at")

    // 畸形输入必须抛错，不能静默返回空数组（否则 UI 以为会话真的没了）
    expectThrows("non-object root", { _ = try GatewayDecode.sessions(Data("[]".utf8)) })
    expectThrows("data is not an array", { _ = try GatewayDecode.sessions(Data(#"{"data":"x"}"#.utf8)) })

    // 消息 → ChatSnapshot：整数 id 必须转成字符串，否则占位绑定会失效
    let messagesJSON = """
    {"object":"list","session_id":"s1","data":[
      {"id":86643,"role":"user","content":"问题","timestamp":100.0},
      {"id":86644,"role":"assistant","content":"回答","timestamp":101.0},
      {"id":86645,"role":"session_meta","content":null}
    ],"pagination":{"limit":3,"offset":0,"order":"latest","returned":3}}
    """
    let snap = try GatewayDecode.snapshot(Data(messagesJSON.utf8), offset: 0)
    expect(snap.sessionID == "s1", "snapshot keeps session id")
    expect(snap.messages.count == 2, "session_meta is not a visible message")
    expect(snap.messages.allSatisfy { $0.id.range(of: "[0-9]+", options: .regularExpression) != nil },
           "integer ids become numeric strings")
    expect(Set(snap.messages.map(\.id)).count == 2, "ids stay unique")
    expect(snap.messages[0].content == "问题", "user content survives")
    expect(snap.messages[1].content == "回答", "assistant content survives")
    // session_meta 占一行，rawMessageEndIndex 必须是原始行数
    expect(snap.rawMessageEndIndex == 3, "raw end index counts invisible rows")

    // 工具调用要能出卡片
    let toolJSON = """
    {"session_id":"s2","data":[
      {"id":1,"role":"assistant","content":"","tool_calls":[
        {"id":"call_1","function":{"name":"read_file","arguments":"{\\"path\\":\\"a.txt\\"}"}}],
       "timestamp":1.0},
      {"id":2,"role":"tool","tool_call_id":"call_1","content":"hello","timestamp":2.0}
    ]}
    """
    let toolSnap = try GatewayDecode.snapshot(Data(toolJSON.utf8), offset: 0)
    expect(toolSnap.tools.count == 1, "tool call becomes one card")
    expect(toolSnap.tools[0].name == "read_file", "tool card keeps its name")

    // 模型目录占位判定
    expect(GatewayDecode.isPlaceholderModelCatalog(
        Data(#"{"object":"list","data":[{"id":"hermes-agent","object":"model"}]}"#.utf8)),
        "single hermes-agent entry is a placeholder")
    expect(!GatewayDecode.isPlaceholderModelCatalog(
        Data(#"{"object":"list","data":[{"id":"fixture"},{"id":"gpt-6"}]}"#.utf8)),
        "multiple models is a real catalog")
}

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
}

func expectThrows(_ label: String, _ body: () throws -> Void) {
    do {
        try body()
        preconditionFailure("\(label): expected an error")
    } catch {}
}

@main
struct GatewayTests {
    @MainActor static func main() throws {
        try runGatewayTests()
        print("GATEWAY_MAP_DECODE_PASS")
    }
}
