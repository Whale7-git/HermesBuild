import Foundation
import FoundationNetworking

/// 并发探针：记录同时在途的读取数峰值。
///
/// 用 actor 而不是 @MainActor，因为 `load` 闭包在 `GatewayHistoryReader` 的
/// `@MainActor` 上下文外被调用；actor 保证 enter/leave 的计数不被并发撕裂。
actor ConcurrencyProbe {
    private var inFlight = 0
    private(set) var peak = 0
    func enter() {
        inFlight += 1
        if inFlight > peak { peak = inFlight }
    }
    func leave() { inFlight -= 1 }
}

@MainActor final class FixtureTransport: GatewayTransport {
    var rows: [[String: Any]] = (0..<121).map { ["id": $0 + 1, "role": "user", "content": "row \($0)"] }
    var countHint = 121
    var status = "running"
    var statusCode = 200
    var failure: Error?
    var requests: [URLRequest] = []
    var frames: [SSEFrame] = []
    var manySessions = false
    var modelCode = 401
    var uploadCode = 200
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        let url = request.url!
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var body: [String: Any] = [:]
        var code = 200
        if url.path == "/v1/files", request.httpMethod == "POST" {
            body = ["filename": "fixture.txt", "path": "/state/attachments/s/fixture.txt",
                    "bytes": 4, "mime": "text/plain", "is_image": false]
            code = uploadCode
        } else if url.path == "/v1/runs", request.httpMethod == "POST" {
            body = ["run_id": "run-fixture", "status": "queued"]
        } else if url.path == "/v1/runs/run-fixture" {
            body = ["run_id": "run-fixture", "session_id": "s", "status": status]
            code = statusCode
        } else if url.path.hasSuffix("/stop") {
            code = statusCode
        } else if url.path == "/api/sessions/s" {
            body = ["session": ["id": "s", "message_count": countHint, "model": "fixture-model"]]
        } else if url.path.hasSuffix("/messages") {
            precondition(q["order"] == "oldest", "history uses append-stable offsets")
            let start = Int(q["offset"] ?? "0")!, limit = Int(q["limit"] ?? "60")!
            let slice = Array(rows.dropFirst(start).prefix(limit))
            body = ["session_id": "s", "data": slice, "pagination": ["returned": slice.count]]
        } else if url.path == "/api/sessions" {
            let start = Int(q["offset"] ?? "0")!, limit = Int(q["limit"] ?? "200")!
            let total = manySessions ? 451 : 0
            var data: [[String: Any]] = start < total ? (start..<min(total, start + limit)).map { ["id": "s\($0)", "title": "session \($0)", "pinned": false] } : []
            if manySessions { data.append(["id": "pin", "title": "pin", "pinned": true]) }
            body = ["data": data, "has_more": start + limit < total]
        } else if url.path == "/api/model/options" {
            code = modelCode
        } else { preconditionFailure("unexpected fixture request \(url.path)") }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    /// 上传走同一个替身：测试里不需要区分两个 session，行为一致即可。
    /// 协议要求这个方法存在，是为了让生产实现能把上传放到 120s 资源上限的
    /// 独立 session 上——替身不复制那条超时策略。
    func uploadData(for request: URLRequest,
                    onProgress: (@Sendable (AttachmentTransferProgress) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        try await data(for: request)
    }

    func events(for request: URLRequest, onFrame: (SSEFrame) async throws -> Bool) async throws {
        requests.append(request)
        for frame in frames { if try await onFrame(frame) { return } }
    }
}

@main struct GatewayBackendTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ why: String) { checks += 1; precondition(value, why) }
        let transport = FixtureTransport()
        let suite = "HermesGatewayTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func backend(scope: String = "instance|account") -> GatewayBackend {
            GatewayBackend(gatewayBaseURL: URL(string: "https://fixture.invalid")!, apiKey: "fixture-only",
                           webuiBaseURL: URL(string: "https://fallback.invalid")!, transport: transport,
                           runStore: GatewayRunStore(scope: scope, defaults: defaults))
        }
        let first = backend()
        var uploadRequest = URLRequest(url: URL(string: "https://fixture.invalid/v1/files")!)
        uploadRequest.httpMethod = "POST"
        uploadRequest.httpBody = Data("test".utf8)
        let uploaded = try await first.uploadAttachment(uploadRequest, onProgress: nil)
        let parsedUpload = try JSONSerialization.jsonObject(with: uploaded) as? [String: Any]
        check(parsedUpload?["bytes"] as? Int == 4
              && (parsedUpload?["path"] as? String)?.hasSuffix("/fixture.txt") == true,
              "Gateway Files API response is accepted")
        check(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only",
              "Gateway multipart request carries its own Bearer credential")
        check(first.attachmentPreviewAuthorization == .bearer("fixture-only"),
              "Gateway preview always uses Bearer even when legacy WebUI URL exists")
        var evilUpload = uploadRequest
        evilUpload.url = URL(string: "https://foreign.example/v1/files")!
        let requestCount = transport.requests.count
        do {
            _ = try await first.uploadAttachment(evilUpload, onProgress: nil)
            preconditionFailure("cross-origin file request accepted")
        } catch {
            check(transport.requests.count == requestCount, "cross-origin upload fails before transport")
        }
        var wrongMethod = uploadRequest
        wrongMethod.httpMethod = "GET"
        let beforeWrongMethod = transport.requests.count
        do {
            _ = try await first.uploadAttachment(wrongMethod, onProgress: nil)
            preconditionFailure("non-POST upload accepted")
        } catch {
            check(transport.requests.count == beforeWrongMethod,
                  "non-POST upload rejected before transport")
        }
        let emptyKeyBackend = GatewayBackend(gatewayBaseURL: URL(string: "https://fixture.invalid")!,
                                             apiKey: "", webuiBaseURL: nil, transport: transport,
                                             runStore: GatewayRunStore(scope: "empty-key", defaults: defaults))
        let beforeEmptyKey = transport.requests.count
        do {
            _ = try await emptyKeyBackend.uploadAttachment(uploadRequest, onProgress: nil)
            preconditionFailure("empty Gateway key was accepted")
        } catch {
            check(transport.requests.count == beforeEmptyKey,
                  "empty API key rejected before transport")
        }
        transport.uploadCode = 404
        do {
            _ = try await first.uploadAttachment(uploadRequest, onProgress: nil)
            preconditionFailure("404 was treated as upload success")
        } catch {
            check(true, "missing Files API does not silently fall back to WebUI")
        }
        transport.uploadCode = 200
        transport.countHint = 100
        let tail = try await first.history(sessionID: "s", before: nil)
        check(tail.olderOffset == 61 && tail.rawMessageEndIndex == 121, "stale count cannot relabel latest rows")
        check(tail.messages.first?.sourceIndex == 61 && tail.messages.first?.content == "row 61", "absolute identity matches actual source window")
        for i in 121..<151 { transport.rows.append(["id": i + 1, "role": "user", "content": "row \(i)"]) }
        let older = try await first.history(sessionID: "s", before: 61)
        check(older.olderOffset == 1 && older.rawMessageEndIndex == 61, "appends cannot shift an older page")
        check(older.messages.first?.content == "row 1" && older.messages.last?.content == "row 60", "no older rows skipped or duplicated")
        transport.rows.removeFirst()
        do { _ = try await first.history(sessionID: "s", before: 1); preconditionFailure("truncated anchor accepted") }
        catch { check(true, "truncation rejected atomically") }
        let refreshed = try await first.history(sessionID: "s", before: nil)
        check(refreshed.rawMessageEndIndex == 150, "refresh recounts after truncation")
        transport.countHint = 1_000
        let overcount = try await first.history(sessionID: "s", before: nil)
        check(overcount.rawMessageEndIndex == 150 && overcount.olderOffset == 90, "overcount hint repaired")
        let run = try await first.startNativeTurn(sessionID: "s", text: "fixture")
        check(run == "run-fixture", "accepted run recorded")
        let restarted = backend()
        let active = try await restarted.history(sessionID: "s", before: nil)
        check(active.activeStreamID == run, "process recreation recovers active run")
        let other = try await backend(scope: "instance|other-account").history(sessionID: "s", before: nil)
        check(other.activeStreamID == nil, "recovery records isolated by account")
        transport.status = "waiting_for_approval"
        let waiting = try await restarted.history(sessionID: "s", before: nil)
        check(waiting.activeStreamID == run, "approval-waiting run remains recoverable")
        transport.statusCode = 404
        let unknown = try await restarted.history(sessionID: "s", before: nil)
        check(unknown.activeStreamID == run, "missing status is not claimed completed")
        try await restarted.stopNativeTurn(streamID: run)
        let stopped = try await restarted.history(sessionID: "s", before: nil)
        check(stopped.activeStreamID == nil, "explicit stop settles missing run record")
        transport.statusCode = 200
        _ = try await restarted.startNativeTurn(sessionID: "s", text: "fixture")
        transport.failure = URLError(.notConnectedToInternet)
        do { _ = try await restarted.history(sessionID: "s", before: nil); preconditionFailure("offline considered idle") }
        catch { check(GatewayRunStore(scope: "instance|account", defaults: defaults).runID(for: "s") == run, "transport failure retains recovery") }
        transport.failure = nil
        transport.status = "completed"
        let ended = try await restarted.history(sessionID: "s", before: nil)
        check(ended.activeStreamID == nil, "confirmed terminal status clears recovery")

        // build166: 5xx and missing status do not become a guessed completion,
        // even after the bounded budget is exhausted. A fresh status reader can
        // subsequently observe an explicit terminal state and clear the ID.
        let failureScope = "instance|build166-failures"
        let guarded = backend(scope: failureScope)
        _ = try await guarded.startNativeTurn(sessionID: "s", text: "fixture")
        transport.statusCode = 500
        for _ in 0..<4 {
            let provisional = try await guarded.history(sessionID: "s", before: nil)
            check(provisional.activeStreamID == run,
                  "transient 5xx retains the active run for later verification")
        }
        let exhausted = try await guarded.history(sessionID: "s", before: nil)
        check(exhausted.activeStreamID == run,
              "exhausted status budget retains the run as an unresolved hint")
        check(transport.requests.last?.url?.path.hasSuffix("/messages") == true,
              "exhausted status budget still reads canonical history")
        check(GatewayRunStore(scope: failureScope, defaults: defaults)
                  .runID(for: "s") == run,
              "run ID remains durable when the state budget is exhausted")
        let beforeCooldown = transport.requests.count
        let historyDuringBackoff = try await guarded.history(sessionID: "s", before: nil)
        check(historyDuringBackoff.activeStreamID == run,
              "run backoff retains the unresolved ID in the history snapshot")
        let requestsDuringBackoff = transport.requests.dropFirst(beforeCooldown)
        check(!requestsDuringBackoff.contains { $0.url?.path.hasPrefix("/v1/runs/") == true },
              "history backoff suppresses another run-status request")
        check(requestsDuringBackoff.last?.url?.path.hasSuffix("/messages") == true,
              "backoff suppresses the status probe while allowing transcript GET")
        transport.statusCode = 200
        transport.status = "completed"
        let terminalFromFreshReader = try await backend(scope: failureScope)
            .history(sessionID: "s", before: nil)
        check(terminalFromFreshReader.activeStreamID == nil,
              "explicit terminal status retires old run after transient 5xx")
        check(GatewayRunStore(scope: failureScope, defaults: defaults)
                  .runID(for: "s") == nil,
              "verified completion also clears the persisted run identity")

        let unauthScope = "instance|build166-auth"
        let unauth = backend(scope: unauthScope)
        _ = try await unauth.startNativeTurn(sessionID: "s", text: "fixture")
        transport.statusCode = 401
        do {
            _ = try await unauth.history(sessionID: "s", before: nil)
            preconditionFailure("401 was masked as an active run")
        } catch {
            check(unauth.requiresAuthentication(after: error),
                  "authentication errors must not be rewritten as recovery timeouts")
        }
        transport.statusCode = 200
        transport.status = "completed"

        _ = try await restarted.startNativeTurn(sessionID: "s", text: "fixture")
        transport.frames = [SSEFrame(event: "run.failed", data: #"{"error":"fixture failure"}"#, id: "7")]
        var mapped = ""
        try await restarted.streamNativeTurn(streamID: run, lastEventID: "6") { frame in mapped = frame.event; return true }
        check(mapped == "apperror", "run.failed terminates visibly")
        check(GatewayRunStore(scope: "instance|account", defaults: defaults).runID(for: "s") == nil, "terminal event retires persistent run")
        check(transport.requests.last?.value(forHTTPHeaderField: "Last-Event-ID") == "6", "SSE resume sequence reaches transport")
        // A-02：收尾判定在 map 循环之外按原始事件名做。这里给一帧「原始名是终态、
        // 但 data 解析不了 → map 返回空数组」的坏帧：run 必须照样被清掉，并且上层
        // 仍收到一个可见的失败帧，否则这条流永远悬挂、下次启动锁死发送。
        _ = try await restarted.startNativeTurn(sessionID: "s", text: "fixture")
        check(GatewayRunStore(scope: "instance|account", defaults: defaults).runID(for: "s") == run,
              "run is armed again before the malformed terminal frame")
        transport.frames = [SSEFrame(event: "error", data: "not json", id: "8")]
        var malformedTerminal: [String] = []
        try await restarted.streamNativeTurn(streamID: run, lastEventID: nil) { frame in
            malformedTerminal.append(frame.event)
            return true
        }
        check(malformedTerminal == ["apperror"],
              "an unmappable terminal frame still surfaces a visible failure")
        check(GatewayRunStore(scope: "instance|account", defaults: defaults).runID(for: "s") == nil,
              "a terminal frame retires the run even when mapping produced no app frames")
        // 非终态坏帧不能顺手清 run：只有白名单里的原始事件名才有这个权力。
        _ = try await restarted.startNativeTurn(sessionID: "s", text: "fixture")
        transport.frames = [SSEFrame(event: "message.delta", data: "not json", id: "9")]
        var ignoredFrames: [String] = []
        try await restarted.streamNativeTurn(streamID: run, lastEventID: nil) { frame in
            ignoredFrames.append(frame.event)
            return true
        }
        check(ignoredFrames.isEmpty, "a malformed non-terminal frame produces no app frame")
        check(GatewayRunStore(scope: "instance|account", defaults: defaults).runID(for: "s") == run,
              "a malformed non-terminal frame must not retire a live run")
        // 该记录留到后面的 removeAll 一起清；成功 stop 只是「已受理」，按设计不清记录。
        transport.manySessions = true
        let all = try await restarted.sessions()
        check(all.count == 452 && Set(all.map(\.id)).count == 452, "all session pages loaded with pinned dedup")
        let hits = try await restarted.searchSessions(query: "session 450")
        check(hits.hits.contains { $0.id == "s450" }, "search reaches beyond first server page")
        let beforeUnsupported = transport.requests.count
        do { _ = try await restarted.forkSession(sessionID: "s", keepCount: 5); preconditionFailure("unsafe full fork accepted") }
        catch { check(transport.requests.count == beforeUnsupported, "unsupported cutoff cannot mutate server") }
        do { try await restarted.setSessionArchived(sessionID: "s", archived: true); preconditionFailure("unrecoverable archive accepted") }
        catch { check(transport.requests.count == beforeUnsupported, "archive without listing cannot hide session") }
        do { _ = try await restarted.archivedSessions(offset: 0, limit: 40); preconditionFailure("false empty archive") }
        catch { check(true, "missing archive contract explicit") }
        do { _ = try await restarted.availableModels(); preconditionFailure("catalog auth swallowed") }
        catch { check(restarted.requiresAuthentication(after: error) && HermesAPI.modelReads == 0, "401 never falls back to another identity") }
        // A-17：网关模式没有密码登录。空实现会让调用方以为登录态已建立，
        // 所以这里必须抛明确错误（501），并且一条请求都不该发出去。
        let beforeLogin = transport.requests.count
        do {
            try await restarted.login(password: "not-a-gateway-password")
            preconditionFailure("A-17: gateway password login silently succeeded")
        } catch {
            guard let apiError = error as? APIError, case .http(let code, _) = apiError else {
                preconditionFailure("A-17: expected an explicit 501, got \(error)")
            }
            check(code == 501, "A-17: gateway password login fails loudly instead of pretending to succeed")
        }
        check(transport.requests.count == beforeLogin,
              "A-17: rejected password login does not send any request")
        let already = GatewayEventMap.map(SSEFrame(event: "message.interim", data: #"{"text":"commentary","already_streamed":true}"#, id: "8"))
        check(already.isEmpty, "already-streamed commentary is not duplicated")
        let snapshot = try GatewayDecode.snapshot(Data(#"{"session_id":"s","active_run_id":"r","data":[]}"#.utf8), offset: 0)
        check(snapshot.activeStreamID == "r", "explicit active run survives decoding")
        GatewayRunStore.removeAll(instanceID: "instance", accountScope: "account", defaults: defaults)
        check(GatewayRunStore(scope: "instance|account", defaults: defaults).runID(for: "s") == nil, "account retirement cleans recovery records")
        let retired = GatewayRunStore(scope: "instance|account", defaults: defaults)
        retired.remember(runID: "old", sessionID: "a")
        GatewayRunStore.removeAll(instanceID: "instance", accountScope: "account", defaults: defaults)
        retired.remember(runID: "late", sessionID: "a")
        let fresh = GatewayRunStore(scope: "instance|account", defaults: defaults)
        check(fresh.runID(for: "a") == nil, "late callback cannot resurrect retired records")
        let peer = GatewayRunStore(scope: "instance|account", defaults: defaults)
        fresh.remember(runID: "new", sessionID: "b")
        peer.finish(runID: "unrelated")
        check(fresh.runID(for: "b") == "new", "peer completion cannot overwrite a newer record")
        // F-55d：`runStore` 是 private，写盘失败标记必须由 backend 转发出去，
        // 否则 UI 永远拿不到「本轮恢复能力不可用」。
        // 这里用新建 backend 走一次真实的 `remember()` 写盘路径（startNativeTurn →
        // runStore.remember → persist → 回读比对），再断言标记仍为 false：
        // 既证明转发可达，也证明正常写入不会被误判成失败。
        // 无法在离线套件里可靠制造 UserDefaults 写失败，故只锁 false 分支。
        let recoveryProbe = backend(scope: "instance|recovery-probe")
        check(recoveryProbe.runRecoveryUnavailable == false,
              "F-55d: recovery is available before any write is attempted")
        _ = try await recoveryProbe.startNativeTurn(sessionID: "probe", text: "fixture")
        check(recoveryProbe.runRecoveryUnavailable == false,
              "F-55d: a successful run-record write is not misreported as unavailable")
        var budget = SSEFrameBudget(maxBytes: 32)
        for _ in 0..<3 { for byte in "data: small\r\n\r\n".utf8 { try budget.consume(byte) } }
        check(true, "CRLF event delimiters reset budget")

        // F-78：`has_more` 恒真 + 每页都在前进（永远有新会话）时，翻页不能无限打下去。
        // 这里直接驱动 `GatewaySessionReader.all`，用一个「永远还有下一页、每页只回
        // 1 条」的假服务端：请求数必须有硬上限，且超限后抛可读的 429，而不是
        // 静默返回半份列表或一直转圈。
        //
        // 计数直接用局部变量：`load` 是非逃逸闭包（`all` 的签名里没有 `@escaping`），
        // 和本文件其它测试改局部变量的写法一致。
        var pageLoads = 0
        let pagingRequests = GatewayRequests(baseURL: URL(string: "https://fixture.invalid")!,
                                             apiKey: "fixture-only")
        do {
            _ = try await GatewaySessionReader.all(requests: pagingRequests) { request in
                pageLoads += 1
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let rawOffset = query.first(where: { $0.name == "offset" })?.value ?? "0"
                let offset = Int(rawOffset) ?? 0
                // 每页只回 1 条，且 id 随 offset 变化：服务端确实在前进，
                // 所以「没有前进」的检测不会先触发，只能靠请求预算收口。
                return try JSONSerialization.data(withJSONObject: [
                    "data": [["id": "endless\(offset)", "title": "s\(offset)"]],
                    "has_more": true,
                ])
            }
            preconditionFailure("F-78: unbounded pagination was accepted")
        } catch {
            guard let apiError = error as? APIError, case .http(let code, let message) = apiError else {
                preconditionFailure("F-78: expected a readable 429, got \(error)")
            }
            check(code == 429 && message.contains("仍未收敛"),
                  "F-78: budget exhaustion surfaces a readable 429 instead of a silent partial list")
        }
        check(pageLoads == GatewaySessionPaging.maxRequests,
              "F-78: pagination stops at exactly the documented request budget (got \(pageLoads))")

        // build159: five fully filtered pages are NOT end-of-list when
        // has_more remains true; do not return silently truncated results.
        var filteredCalls = 0
        do {
            _ = try await GatewaySessionReader.all(requests: pagingRequests) { _ in
                filteredCalls += 1
                return try JSONSerialization.data(withJSONObject: [
                    "data": [["id": "hidden-\(filteredCalls)", "title": "hidden",
                              "is_internal_child": true]],
                    "has_more": true
                ])
            }
            preconditionFailure("incomplete filtered pagination returned success")
        } catch {
            check("\(error)".contains("未读取完整"),
                  "filtered-page cutoff reports incomplete history rather than a complete list")
            check(filteredCalls == GatewaySessionPaging.maxFullyFilteredPages,
                  "fully filtered pagination has a strict request bound")
        }

        // F-23：分页锚点的淘汰行为必须有测试锁住。
        // 直接驱动 `GatewayHistoryReader`（不走 transport），每个会话一次
        // metadata + 一次 messages，两条请求都由下面的闭包就地合成。
        // 每个会话只有 3 行、从 0 开始取，所以一次读取就收敛到真实尾部，
        // `remember()` 会为该会话记下 offset 0 的锚点。
        let reader = GatewayHistoryReader()
        let sessionsToInsert = GatewayAnchorLimits.sessions + 6   // 70 个，故意越过上限
        for index in 0..<sessionsToInsert {
            let id = "sess\(index)"
            _ = try await reader.read(sessionID: id, before: nil, requests: pagingRequests) { request in
                let url = request.url!
                let path = url.path
                if path.hasSuffix("/messages") {
                    // 3 行固定历史：id 带会话前缀，锚点值才能区分是哪个会话的。
                    let rows: [[String: Any]] = (1...3).map { row -> [String: Any] in
                        ["id": "\(id)-\(row)", "role": "user", "content": "row \(row)"]
                    }
                    return try JSONSerialization.data(withJSONObject: [
                        "session_id": id, "data": rows,
                        "pagination": ["returned": rows.count],
                    ])
                }
                return try JSONSerialization.data(withJSONObject: [
                    "session": ["id": id, "message_count": 3],
                ])
            }
        }
        let anchorSnapshot = reader.anchorSnapshotForTesting()
        check(anchorSnapshot.sessions.count == GatewayAnchorLimits.sessions,
              "F-23: session order is capped at the documented limit, not left unbounded")
        check(anchorSnapshot.sessions == (6..<sessionsToInsert).map { "sess\($0)" },
              "F-23: eviction drops the OLDEST sessions in insertion order, keeping the newest N")
        check(anchorSnapshot.anchorCounts["sess0"] == nil && anchorSnapshot.anchorCounts["sess5"] == nil,
              "F-23: anchors of the evicted (oldest) sessions are gone, not just the order entry")
        check(anchorSnapshot.anchorCounts["sess6"] == 1 && anchorSnapshot.anchorCounts["sess69"] == 1,
              "F-23: every surviving session keeps its own anchor")
        check(anchorSnapshot.anchorCounts.count == GatewayAnchorLimits.sessions,
              "F-23: the anchor dictionary is bounded together with the order list")

        // F-23（续）：单会话锚点上限 `anchorsPerSession` 此前没有任何断言，
        // 且计数快照看不出「被丢的是哪一页」。这里用独立 reader，每轮让 metadata
        // 自报 `60 + k` 条，首次读取就落在 `start == k`，于是能在 offset k 精确种一个锚点。
        let soloReader = GatewayHistoryReader()
        let soloSession = "solo"
        let soloInserts = GatewayAnchorLimits.anchorsPerSession + 44   // 300，故意越过 256
        for offset in 0..<soloInserts {
            let total = 60 + offset
            _ = try await soloReader.read(sessionID: soloSession, before: nil,
                                          requests: pagingRequests) { request in
                let url = request.url!
                if url.path.hasSuffix("/messages") {
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let start = Int(query.first { $0.name == "offset" }?.value ?? "0")!
                    let limit = Int(query.first { $0.name == "limit" }?.value ?? "60")!
                    let rows: [[String: Any]] = (0..<Swift.max(0, Swift.min(limit, total - start))).map { i in
                        ["id": "solo-\(start + i)", "role": "user", "content": "row"]
                    }
                    return try JSONSerialization.data(withJSONObject: [
                        "session_id": soloSession, "data": rows,
                        "pagination": ["returned": rows.count],
                    ])
                }
                return try JSONSerialization.data(withJSONObject: [
                    "session": ["id": soloSession, "message_count": total],
                ])
            }
        }
        let soloOffsets = soloReader.anchorOffsetsForTesting(sessionID: soloSession)
        check(soloOffsets.count == GatewayAnchorLimits.anchorsPerSession,
              "F-23: one session's page anchors are capped at the documented limit, not left unbounded")
        check(soloOffsets.last == soloInserts - 1,
              "F-23: the newest page anchor of a busy session survives its own cap")
        check(soloOffsets.first == soloInserts - GatewayAnchorLimits.anchorsPerSession,
              "F-23: per-session eviction drops the SMALLEST offset (oldest page) first, not an arbitrary one")

        // F-23（续）：淘汰序必须是「最近写入」而非「最早插入」。老会话被重读一次后
        // 应移到队尾，下一次淘汰落到的必须是真正最久没写过的那个。
        let lruReader = GatewayHistoryReader()
        for index in 0..<GatewayAnchorLimits.sessions {
            let id = "lru\(index)"
            _ = try await lruReader.read(sessionID: id, before: nil, requests: pagingRequests) { request in
                let url = request.url!
                if url.path.hasSuffix("/messages") {
                    let rows: [[String: Any]] = (1...3).map { row in
                        ["id": "\(id)-\(row)", "role": "user", "content": "row"]
                    }
                    return try JSONSerialization.data(withJSONObject: [
                        "session_id": id, "data": rows, "pagination": ["returned": rows.count],
                    ])
                }
                return try JSONSerialization.data(withJSONObject: ["session": ["id": id, "message_count": 3]])
            }
        }
        for id in ["lru0", "lruNew"] {
            _ = try await lruReader.read(sessionID: id, before: nil, requests: pagingRequests) { request in
                let url = request.url!
                if url.path.hasSuffix("/messages") {
                    let rows: [[String: Any]] = (1...3).map { row in
                        ["id": "\(id)-\(row)", "role": "user", "content": "row"]
                    }
                    return try JSONSerialization.data(withJSONObject: [
                        "session_id": id, "data": rows, "pagination": ["returned": rows.count],
                    ])
                }
                return try JSONSerialization.data(withJSONObject: ["session": ["id": id, "message_count": 3]])
            }
        }
        let lruSnapshot = lruReader.anchorSnapshotForTesting()
        check(lruSnapshot.sessions.count == GatewayAnchorLimits.sessions,
              "F-23: refreshing an existing session does not grow the order past the cap")
        check(lruSnapshot.sessions.contains("lru0"),
              "F-23: re-reading an old session refreshes its LRU position, so it is not evicted next")
        check(!lruSnapshot.sessions.contains("lru1"),
              "F-23: the least recently WRITTEN session is evicted, not the oldest-inserted one")
        check(lruSnapshot.sessions.last == "lruNew" && lruSnapshot.anchorCounts["lruNew"] == 1,
              "F-23: a newly written session lands at the tail of the order together with its anchor")

        // F-68：同一轮内两个同名工具 + 结果行缺 tool_call_id 时，绝不能按 FIFO
        // 挂到先发起的那个调用上——那样参数和结果会张冠李戴。期望是「不认领」，
        // 两条结果各自成卡并在名字上标出「未能关联」。
        let ambiguousJSON = """
        {"session_id":"s","data":[
          {"id":1,"role":"assistant","content":"","tool_calls":[
            {"id":"c1","function":{"name":"read_file","arguments":"{\\"path\\":\\"a.txt\\"}"}},
            {"id":"c2","function":{"name":"read_file","arguments":"{\\"path\\":\\"b.txt\\"}"}}]},
          {"id":2,"role":"tool","tool_name":"read_file","content":"result A"},
          {"id":3,"role":"tool","tool_name":"read_file","content":"result B"}
        ]}
        """
        let ambiguous = try GatewayDecode.snapshot(Data(ambiguousJSON.utf8), offset: 0)
        let unlinkedCards = ambiguous.tools.filter { $0.name == "read_file（未能关联）" }
        check(unlinkedCards.count == 2,
              "F-68: same-name calls in one turn leave id-less results unlinked instead of guessing")
        check(unlinkedCards.map(\.result).sorted() == ["result A", "result B"],
              "F-68: unlinked results keep their own payload, not merged into a wrong call")
        let callOnlyCards = ambiguous.tools.filter { $0.name == "read_file" }
        check(callOnlyCards.count == 2 && callOnlyCards.allSatisfy { $0.result.isEmpty },
              "F-68: neither ambiguous call card absorbed a result it cannot prove belongs to it")

        // 对照组：同名工具只发起一次时，缺 id 的结果仍应按名字认领（不能一刀切）。
        let unambiguousJSON = """
        {"session_id":"s","data":[
          {"id":1,"role":"assistant","content":"","tool_calls":[
            {"id":"c1","function":{"name":"read_file","arguments":"{\\"path\\":\\"a.txt\\"}"}}]},
          {"id":2,"role":"tool","tool_name":"read_file","content":"only result"}
        ]}
        """
        let unambiguous = try GatewayDecode.snapshot(Data(unambiguousJSON.utf8), offset: 0)
        check(unambiguous.tools.count == 1 && unambiguous.tools[0].result == "only result",
              "F-68: a single same-name call still links by name (no over-correction)")

        // 结果行自带 id 时，必须把它从名字队列里摘掉：否则同轮后面那条缺 id 的
        // 结果行会再认领同一个 callID，两条结果挤进同一张卡（第二次认领是错的）。
        let explicitThenImplicitJSON = """
        {"session_id":"s","data":[
          {"id":1,"role":"assistant","content":"","tool_calls":[
            {"id":"c1","function":{"name":"read_file","arguments":"{}"}}]},
          {"id":2,"role":"tool","tool_name":"read_file","tool_call_id":"c1","content":"explicit"},
          {"id":3,"role":"tool","tool_name":"read_file","content":"implicit"}
        ]}
        """
        let explicitThenImplicit = try GatewayDecode.snapshot(Data(explicitThenImplicitJSON.utf8), offset: 0)
        let explicitCards = explicitThenImplicit.tools.filter { $0.id == "c1" }
        check(explicitCards.count == 1 && explicitCards[0].result == "explicit",
              "F-68: an id-carrying result keeps its own card and is not overwritten by the next id-less row")
        check(explicitThenImplicit.tools.contains { $0.result == "implicit" && $0.id != "c1" },
              "F-68: a following id-less result becomes its own card instead of re-claiming the same call")

        do {
            for byte in "data: small\ndata: small\ndata: small\n".utf8 { try budget.consume(byte) }
            preconditionFailure("multiline event bypassed memory limit")
        } catch { check(true, "aggregate event limit rejects many short lines") }

        // MARK: clarify（补充信息）
        //
        // 合同与审批不同，三处最容易写错的地方必须钉住：
        // ① 事件名是 `clarify.request`（不是 `clarify`），原来客户端判的 `clarify`
        //    根本收不到——映射表没有这一条，帧会落到 default 被丢掉；
        // ② 答复体必须是 {request_id, execution_generation, answer} 三件套，
        //    字段名是 answer 而不是 choice；
        // ③ 载荷里的 prompt_id 要变成请求体的 request_id。

        // ① 映射：完整载荷
        let clarifyFrame = SSEFrame(event: "message", data: """
        {"event":"clarify.request","run_id":"run-x","prompt_id":"p-1",
         "execution_generation":7,"question":"要覆盖还是重命名？",
         "choices":["覆盖","重命名"],"multi_select":false}
        """, id: "e1")
        let clarifyMapped = GatewayEventMap.map(clarifyFrame)
        check(clarifyMapped.count == 1 && clarifyMapped[0].event == "clarify",
              "clarify.request maps to a clarify frame (it was previously dropped as unknown)")
        let clarifyPending = clarifyMapped.first.flatMap { ChatPendingClarify.make(from: $0, runID: "run-x") }
        check(clarifyPending?.requestID == "p-1" && clarifyPending?.executionGeneration == 7,
              "clarify carries prompt_id and execution_generation through the map")
        check(clarifyPending?.question == "要覆盖还是重命名？",
              "clarify question survives (not description/command like approval)")
        check(clarifyPending?.choices == ["覆盖", "重命名"] && clarifyPending?.isOpenEnded == false,
              "clarify choices are arbitrary text, not the once/deny whitelist")

        // ② 开放式提问：没有 choices，也不能被当成审批的白名单过滤掉
        let openFrame = SSEFrame(event: "message", data: """
        {"event":"clarify.request","run_id":"run-x","prompt_id":"p-2",
         "execution_generation":3,"question":"给这个文件起个名字"}
        """, id: "e2")
        let openPending = GatewayEventMap.map(openFrame).first
            .flatMap { ChatPendingClarify.make(from: $0, runID: "run-x") }
        check(openPending?.isOpenEnded == true && openPending?.choices.isEmpty == true,
              "an open-ended clarify has no choices and still parses")

        // ③ 缺 execution_generation 时必须拒绝解析：留着卡片只会换来一个 400
        let noGenFrame = SSEFrame(event: "message", data: """
        {"event":"clarify.request","run_id":"run-x","prompt_id":"p-3","question":"选一个"}
        """, id: "e3")
        check(GatewayEventMap.map(noGenFrame).first
                .flatMap { ChatPendingClarify.make(from: $0, runID: "run-x") } == nil,
              "a clarify without execution_generation is refused (it could only 400)")

        // ④ settled 必须能收掉卡片
        let settledFrame = SSEFrame(event: "message", data: """
        {"event":"clarify.settled","run_id":"run-x","prompt_id":"p-1"}
        """, id: "e4")
        let settledMapped = GatewayEventMap.map(settledFrame)
        check(settledMapped.count == 1 && settledMapped[0].event == "clarify_resolved",
              "clarify.settled maps to clarify_resolved so the card is retired")
        let settledBody = (try? JSONSerialization.jsonObject(with: Data(settledMapped[0].data.utf8))) as? [String: Any]
        check(settledBody?["request_id"] as? String == "p-1",
              "clarify_resolved carries the prompt_id as request_id for exact matching")

        // ⑤ 请求体合同：三件套，字段名 answer，不能混进 choice
        let requests = GatewayRequests(baseURL: URL(string: "http://gw.local")!, apiKey: "k")
        let clarifyRequest = try requests.clarifyRun(
            runID: "run-x", answer: "重命名", requestID: "p-1", executionGeneration: 7)
        check(clarifyRequest.url?.path == "/v1/runs/run-x/clarify",
              "clarify POSTs to /v1/runs/{id}/clarify")
        let sentBody = (try? JSONSerialization.jsonObject(with: clarifyRequest.httpBody ?? Data())) as? [String: Any]
        let clarifyBodyKeys = Set((sentBody ?? [:]).keys.map { String($0) })
        check(clarifyBodyKeys == Set(["request_id", "execution_generation", "answer"]),
              "clarify body is exactly {request_id, execution_generation, answer} — respond_run rejects anything else")
        check(sentBody?["answer"] as? String == "重命名",
              "clarify sends the raw answer text; the server owns all parsing")
        check(sentBody?["execution_generation"] as? Int == 7,
              "clarify echoes execution_generation unchanged")
        check(sentBody?["choice"] == nil,
              "clarify never sends approval's `choice` field")

        // ⑥ 审批的合同不能被改动（clarify 加进来时最容易顺手改坏这里）
        let approvalRequest = try requests.approveRun(runID: "run-x", choice: "once", requestID: "p-9")
        let approvalBody = (try? JSONSerialization.jsonObject(with: approvalRequest.httpBody ?? Data())) as? [String: Any]
        check(approvalRequest.url?.path == "/v1/runs/run-x/approval",
              "approval still POSTs to /v1/runs/{id}/approval")
        let approvalBodyKeys = Set((approvalBody ?? [:]).keys.map { String($0) })
        check(approvalBodyKeys == Set(["choice", "request_id"]),
              "approval body stays {choice, request_id} — no execution_generation, no answer")

        // F-XX（P0）：同会话并发读取必须真正串行。
        //
        // 旧实现把「等待上一棒」放进链里，`readSerialized()` 却在链外执行：
        //   let task = Task { _ = await previous?.value }   // 只等空壳
        //   await task.value
        //   return try await readSerialized(...)            // 与上一棒并发
        // 于是并发刷新会交错 `remember()`，后完成的写入覆盖先完成的锚点。
        //
        // 这里用 `load` 闭包记录在途峰值。串行正确时同会话峰值恒为 1；
        // 旧实现下后发起的读取立刻进入 `readSerialized`，峰值必然 > 1。
        let concurrencyReader = GatewayHistoryReader()
        let concurrencySession = "serial"
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try await concurrencyReader.read(
                        sessionID: concurrencySession, before: nil,
                        requests: pagingRequests) { request in
                            await probe.enter()
                            // 让出足够时间，给并发读取一个交错的窗口。
                            try? await Task.sleep(nanoseconds: 15_000_000)
                            await probe.leave()
                            let url = request.url!
                            if url.path.hasSuffix("/messages") {
                                let rows: [[String: Any]] = (1...3).map { row in
                                    ["id": "\(concurrencySession)-\(row)", "role": "user", "content": "row"]
                                }
                                return try JSONSerialization.data(withJSONObject: [
                                    "session_id": concurrencySession, "data": rows,
                                    "pagination": ["returned": rows.count],
                                ])
                            }
                            return try JSONSerialization.data(withJSONObject: [
                                "session": ["id": concurrencySession, "message_count": 3],
                            ])
                        }
                }
            }
            try await group.waitForAll()
        }
        let peak = await probe.peak
        check(peak == 1,
              "P0: reads of the SAME session must be serialized — peak in-flight was \(peak), anchors would interleave")

        // 串行化不能退化成全局锁：不同会话仍应能并发，否则刷新列表会被拖慢。
        let crossReader = GatewayHistoryReader()
        let crossProbe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask {
                    let id = "cross\(index)"
                    _ = try await crossReader.read(sessionID: id, before: nil,
                                                   requests: pagingRequests) { request in
                        await crossProbe.enter()
                        try? await Task.sleep(nanoseconds: 15_000_000)
                        await crossProbe.leave()
                        let url = request.url!
                        if url.path.hasSuffix("/messages") {
                            let rows: [[String: Any]] = (1...3).map { row in
                                ["id": "\(id)-\(row)", "role": "user", "content": "row"]
                            }
                            return try JSONSerialization.data(withJSONObject: [
                                "session_id": id, "data": rows,
                                "pagination": ["returned": rows.count],
                            ])
                        }
                        return try JSONSerialization.data(withJSONObject: [
                            "session": ["id": id, "message_count": 3],
                        ])
                    }
                }
            }
            try await group.waitForAll()
        }
        let crossPeak = await crossProbe.peak
        check(crossPeak > 1,
              "P0: different sessions must still read concurrently — peak was \(crossPeak), the chain became a global lock")

        // build159: a cancelled FIFO waiter must not start a second history
        // request after ownership is transferred, even across the grant race.
        let cancelReader = GatewayHistoryReader()
        var releaseHeldRead: CheckedContinuation<Void, Never>?
        let firstRead = Task {
            try await cancelReader.read(sessionID: "cancel-read", before: nil,
                                        requests: pagingRequests) { request in
                if request.url!.path == "/api/sessions/cancel-read" {
                    await withCheckedContinuation { releaseHeldRead = $0 }
                    return try JSONSerialization.data(withJSONObject: [
                        "session": ["id": "cancel-read", "message_count": 1]
                    ])
                }
                return try JSONSerialization.data(withJSONObject: [
                    "session_id": "cancel-read",
                    "data": [["id": "one", "role": "user", "content": "one"]],
                    "pagination": ["returned": 1]
                ])
            }
        }
        while releaseHeldRead == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var cancelledLoads = 0
        let cancelledRead = Task {
            try await cancelReader.read(sessionID: "cancel-read", before: nil,
                                        requests: pagingRequests) { _ in
                cancelledLoads += 1
                return Data()
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancelledRead.cancel()
        releaseHeldRead?.resume()
        releaseHeldRead = nil
        _ = try await firstRead.value
        do {
            _ = try await cancelledRead.value
            preconditionFailure("cancelled waiter was allowed to read")
        } catch is CancellationError {
            check(cancelledLoads == 0,
                  "cancelled history waiter never reaches its network loader")
        }
        // A subsequent read must acquire the same session normally; no
        // cancelled continuation is allowed to keep a phantom permit.
        let afterCancel = try await cancelReader.read(sessionID: "cancel-read", before: nil,
                                                     requests: pagingRequests) { request in
            if request.url!.path.hasSuffix("/messages") {
                return try JSONSerialization.data(withJSONObject: [
                    "session_id": "cancel-read",
                    "data": [["id": "one", "role": "user", "content": "one"]],
                    "pagination": ["returned": 1]
                ])
            }
            return try JSONSerialization.data(withJSONObject: [
                "session": ["id": "cancel-read", "message_count": 1]
            ])
        }
        check(!afterCancel.data.isEmpty, "cancelled waiter never leaks a session read permit")

        // P1：网关列表接口不返回 is_streaming，必须由本地 runStore 补齐。
        //
        // 否则 `AppState.markCompletions` 依赖的「上一轮 true → 这一轮非 true」
        // 永不成立，后台完成圆点与通知在纯网关模式下从不触发。
        let streamingScope = "streaming|account"
        let streamingStore = GatewayRunStore(scope: streamingScope, defaults: defaults)
        let streamingBackend = GatewayBackend(
            gatewayBaseURL: URL(string: "https://fixture.invalid")!, apiKey: "fixture-only",
            webuiBaseURL: URL(string: "https://fallback.invalid")!, transport: transport,
            runStore: streamingStore)
        transport.manySessions = true
        let beforeRun = try await streamingBackend.sessions()
        check(beforeRun.allSatisfy { $0.isStreaming == false },
              "P1: with no active run, every gateway session reports isStreaming == false (not nil)")

        // 记一条 run，该会话就必须被标成 streaming。
        let liveSession = beforeRun.first?.sessionId ?? "s0"
        streamingStore.remember(runID: "run-live", sessionID: liveSession)
        let duringRun = try await streamingBackend.sessions()
        let liveRow = duringRun.first { $0.sessionId == liveSession }
        check(liveRow?.isStreaming == true,
              "P1: a session with an unfinished run is reported as streaming so completions can be detected")
        check(duringRun.filter { $0.sessionId != liveSession }.allSatisfy { $0.isStreaming == false },
              "P1: only the session that owns the run is marked streaming")

        // run 收尾后必须回落，否则完成通知永远不会触发。
        streamingStore.finish(runID: "run-live")
        let afterRun = try await streamingBackend.sessions()
        check(afterRun.first { $0.sessionId == liveSession }?.isStreaming == false,
              "P1: a finished run clears the streaming flag, which is what the completion detector keys on")
        transport.manySessions = false

        print("GATEWAY_BACKEND_PASS \(checks) assertions; scripted transport, no production requests")
    }
}
