import Foundation

@MainActor
enum RecorderChecks {
    static var checks = 0

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }

    static func run() {
        let recorder = RuntimeLogRecorder.shared

        // F-77：`canRead` 已改为 fail-closed —— 未登记 appScope 时一律拒绝，
        // 防止冷启动瞬间跨账号读到别人的日志。所以测试必须先登记应用级作用域，
        // 否则下面所有跨作用域断言都会因为「一律拒绝」而误判。
        _ = recorder.configureAppScope(instanceID: "inst", accountScope: "acct")

        // 1. A normal record lands in its own scope.
        let tokenA = recorder.beginScope(instanceID: "inst", accountScope: "acct", sessionID: "A")
        recorder.record(.info, "upload", "ok name=a.png size=10", token: tokenA)
        check(recorder.snapshot(token: tokenA).contains("a.png"), "token A records into scope A")

        // 2. A late callback from A must not leak into B.
        let tokenB = recorder.beginScope(instanceID: "inst", accountScope: "acct", sessionID: "B")
        recorder.record(.info, "upload", "ok name=late-a.png path=/srv/x/late-a.png", token: tokenA)
        check(!recorder.snapshot(token: tokenB).contains("late-a"), "expired token is dropped, never redirected")
        check(recorder.snapshot(token: tokenB).isEmpty, "scope B stays clean")

        // 3. A stale view must not end the newer scope.
        recorder.endScope(tokenA)
        recorder.record(.info, "chat", "still alive", token: tokenB)
        check(recorder.snapshot(token: tokenB).contains("still alive"), "stale endScope cannot retire a newer scope")

        // 4. Sanitization: paths keep the leaf, URLs lose the query, secrets are redacted,
        //    and newlines cannot break one-entry-per-line parsing.
        recorder.record(.warning, "net",
            "GET https://h.example/api?token=abc123 failed\nfile=/srv/data/uploads/secret-name.pdf key=sk-live",
            token: tokenB)
        let line = recorder.snapshot(token: tokenB)
        check(!line.contains("/srv/data/uploads"), "absolute path prefix removed")
        check(line.contains("secret-name.pdf"), "leaf file name kept for diagnosis")
        check(!line.contains("token=abc123") && line.contains("<redacted>"), "query secret redacted")
        check(!line.contains("\n") || line.split(separator: "\n").count == 2, "recorded message stays on one line")

        // 5. Export requires content and returns a .txt name.
        check(recorder.export(token: tokenB) != nil, "non-empty scope exports")
        check(recorder.export(token: tokenB)?.filename.hasSuffix(".txt") == true, "export is a text file")

        // 6. Retention is bounded.
        for index in 0..<12 {
            recorder.beginScope(instanceID: "inst", accountScope: "acct", sessionID: "s\(index)")
        }
        check(recorder.scopeCount <= 12, "in-memory scopes are bounded")
        recorder.record(.info, "chat", "alive after pruning")
        check(recorder.export() != nil, "active scope still exports after pruning")

        // 7. A closed scope no longer records.
        recorder.endScope()
        recorder.record(.info, "chat", "nothing active")
        check(recorder.snapshot().isEmpty, "no active scope means no writes")

        // 8. 关闭作用域后日志仍然可读：排查路径是「出问题 → 退出会话 → 去设置导出」。
        //    旧实现 endScope 之后 activeToken 为空、缓冲也被下一次 beginScope 重建，
        //    设置页只能拿到空字符串。
        //
        //    F-77 之后 `canRead` 是 fail-closed 且要求 instanceID 与 accountScope
        //    都匹配，所以这里必须留在同一个实例内（原来用 "keep" 是因为旧实现
        //    默认放行，等于在测一条会跨实例读到别人日志的路径）。
        do {
            let scopeToken = recorder.beginScope(instanceID: "inst", accountScope: "acct",
                                                 sessionID: "closed", label: "被关闭的会话")
            recorder.record(.error, "send", "post fail err=offline", token: scopeToken)
            recorder.endScope(scopeToken)
            check(recorder.snapshot().isEmpty, "closed scope is not the active one any more")
            check(recorder.snapshot(token: scopeToken).contains("offline"),
                  "a closed scope keeps its entries for later export")
            let scopes = recorder.recentScopes()
            check(scopes.contains { $0.label == "被关闭的会话" }, "closed scope is offered in the picker")
            check(recorder.export(scopeKey: scopeToken.scope.key) != nil,
                  "a closed scope can still be exported by key")
        }

        // 9. 应用级分区：会话列表页打开设置时没有任何会话作用域，仍要有内容。
        do {
            let appToken = recorder.configureAppScope(instanceID: "app-inst", accountScope: "app-acct")
            recorder.recordApp(.info, "sessions", "ok count=3")
            recorder.recordApp(.error, "auth", "login fail err=401")
            check(recorder.snapshot(scopeKey: appToken.scope.key).contains("count=3"),
                  "app scope records without any session")
            // 重复配置是幂等的，不能清掉已有条目。
            recorder.configureAppScope(instanceID: "app-inst", accountScope: "app-acct")
            check(recorder.snapshot(scopeKey: appToken.scope.key).contains("count=3"),
                  "re-configuring the app scope keeps its entries")
            // 应用分区在裁剪中受保护。
            for index in 0..<20 {
                let token = recorder.beginScope(instanceID: "churn", accountScope: "acct",
                                                sessionID: "c\(index)")
                recorder.record(.info, "chat", "noise", token: token)
            }
            check(recorder.snapshot(scopeKey: appToken.scope.key).contains("login fail"),
                  "the app scope survives scope pruning")
            let scopes = recorder.recentScopes()
            check(scopes.first?.isApp == true, "the app scope sorts first in the picker")
        }

        // 10. 级别：导出时问题条目先列一遍摘要，正文仍按时间顺序。
        do {
            recorder.configureAppScope(instanceID: "lvl", accountScope: "acct")
            let token = recorder.beginScope(instanceID: "lvl", accountScope: "acct", sessionID: "levels")
            recorder.record(.info, "chat", "step one", token: token)
            recorder.record(.error, "send", "post fail err=timeout", token: token)
            recorder.record(.debug, "chat", "detail", token: token)
            let text = recorder.export(token: token)?.text ?? ""
            check(text.hasPrefix("== 问题摘要"), "export starts with a problem summary")
            let summaryEnd = text.range(of: "\n\n")
            check(summaryEnd != nil, "summary is separated from the body")
            let summary = String(text[text.startIndex..<(summaryEnd?.lowerBound ?? text.endIndex)])
            check(summary.contains("post fail") && !summary.contains("step one"),
                  "only warning/error entries are summarised")
            check(text.contains("] I chat step one") && text.contains("] E send post fail"),
                  "body lines carry a level marker and keep their order")
            // 摘要置顶会把 post fail 提前，所以只比较**正文**部分的顺序。
            let body = String(text[(summaryEnd?.upperBound ?? text.startIndex)...])
            check(body.range(of: "step one")!.lowerBound < body.range(of: "post fail")!.lowerBound,
                  "body stays chronological, not severity-sorted")
            recorder.record(.warning, "net",
                            "GET https://private.example/path?token=summary-secret", token: token)
            let diagnostic = recorder.diagnosticProblemSummary()
            check(diagnostic.contains("send ×1") && diagnostic.contains("net ×1"),
                  "experience summary groups problems by level and module")
            check(!diagnostic.contains("post fail") && !diagnostic.contains("private.example")
                  && !diagnostic.contains("summary-secret"),
                  "experience summary excludes messages, URLs and secrets")
            check(diagnostic.split(separator: "\n").count <= 14,
                  "experience summary is bounded")
        }

        // 11. The same scope can be evicted and reopened without reviving an old
        // asynchronous callback's token (generation used to restart at one).
        do {
            let isolated = RuntimeLogRecorder()
            let old = isolated.beginScope(instanceID: "inst", accountScope: "acct", sessionID: "evicted")
            for index in 0..<20 {
                isolated.beginScope(instanceID: "inst", accountScope: "acct", sessionID: "churn-\(index)")
            }
            let fresh = isolated.beginScope(instanceID: "inst", accountScope: "acct", sessionID: "evicted")
            isolated.record(.error, "upload", "stale-secret", token: old)
            isolated.record(.info, "upload", "fresh-only", token: fresh)
            check(!isolated.snapshot(token: fresh).contains("stale-secret"), "eviction never revives stale tokens")
            check(isolated.snapshot(token: fresh).contains("fresh-only"), "the reopened scope accepts its new token")
        }

        // 12. Caller mistakes must not persist common HTTP/JSON secret forms.
        do {
            let isolated = RuntimeLogRecorder()
            // F-77 之后 `canRead` 是 fail-closed：不先登记 appScope 的话
            // `export(token:)` 返回 nil，下面 13 条「不含密钥」的断言会在空串上
            // 全部假通过 —— 那比失败更危险。
            _ = isolated.configureAppScope(instanceID: "private", accountScope: "acct")
            let token = isolated.beginScope(instanceID: "private", accountScope: "acct", sessionID: "secrets")
            let samples = [
                "Authorization: Bearer bearer-fixture\nHTTP 401",
                "Proxy-Authorization: Basic basic-fixture",
                "Cookie: session=cookie-fixture; other=second-cookie-fixture\nHTTP 403",
                #"{"api_key":"json fixture", "refresh_token": "refresh-fixture", "password":"space secret"}"#,
                "key=equals-fixture token: colon-fixture",
                "GET https://user:userinfo-fixture@host.example/file?token=query-fixture#fragment-fixture",
                "GET https://host.example/file#fragment-only-fixture"
            ]
            for sample in samples { isolated.record(.error, "net", sample, token: token) }
            let text = isolated.export(token: token)?.text ?? ""
            for secret in ["bearer-fixture", "basic-fixture", "cookie-fixture", "second-cookie-fixture",
                           "json fixture", "refresh-fixture", "space secret", "equals-fixture", "colon-fixture",
                           "userinfo-fixture", "query-fixture", "fragment-fixture", "fragment-only-fixture"] {
                check(!text.contains(secret), "export redacts \(secret)")
            }
            // 护栏：上面的「不含密钥」只有在文本真的非空时才有意义。
            // 读不到作用域时 export 会返回空串，那些断言会全部假通过。
            check(!text.isEmpty && text.contains("authorization=<redacted>"),
                  "redaction ran on real content, not an empty export")
            check(text.contains("HTTP 401") && text.contains("HTTP 403"), "redaction preserves following diagnostic lines")
            check(isolated.snapshot(token: token).split(separator: "\n").count == samples.count,
                  "each diagnostic remains exactly one physical line")
        }

        // 13. Settings cannot offer another account's retained labels or logs.
        // Local filenames include a complete namespace so the same guarantee
        // survives restart; legacy files are conservatively left unoffered.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-recorder-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let isolated = RuntimeLogRecorder(localDirectory: root)
            isolated.configureAppScope(instanceID: "same-instance", accountScope: "account-a")
            isolated.recordApp(.info, "app", "account A status")
            let a = isolated.beginScope(instanceID: "same-instance", accountScope: "account-a", sessionID: "chat", label: "account A title")
            isolated.record(.error, "send", "account A failure", token: a)
            isolated.endScope(a)
            check(isolated.recentScopes().contains { $0.label == "account A title" }, "closed same-account scopes remain readable")
            isolated.configureAppScope(instanceID: "same-instance", accountScope: "account-b")
            isolated.recordApp(.info, "app", "account B status")
            check(!isolated.recentScopes().contains { $0.label == "account A title" }, "account switch hides previous account's titles")
            check(isolated.snapshot(scopeKey: a.scope.key).isEmpty && isolated.export(scopeKey: a.scope.key) == nil,
                  "a stale settings selection cannot export another account")
            let aScope = RuntimeLogScope(instanceID: "same-instance", accountScope: "account-a", sessionID: "chat")
            let bScope = RuntimeLogScope(instanceID: "same-instance", accountScope: "account-b", sessionID: "chat")
            try! RuntimeLogStorage.save(Data("A".utf8), in: root,
                                       filename: "runtime-log-v2-\(aScope.accountFileKey)-a.txt")
            try! RuntimeLogStorage.save(Data("B".utf8), in: root,
                                       filename: "runtime-log-v2-\(bScope.accountFileKey)-b.txt")
            try! RuntimeLogStorage.save(Data("legacy".utf8), in: root, filename: "runtime-log-old.txt")
            check(RuntimeLogRecorder(localDirectory: root).localSnapshots().isEmpty,
                  "unconfigured startup never offers another account's disk snapshots")
            check(isolated.localSnapshots().map(\.lastPathComponent) == ["runtime-log-v2-\(bScope.accountFileKey)-b.txt"],
                  "disk snapshots are restricted to the current account namespace")
            let restarted = RuntimeLogRecorder(localDirectory: root)
            restarted.configureAppScope(instanceID: "same-instance", accountScope: "account-a")
            check(restarted.localSnapshots().map(\.lastPathComponent) == ["runtime-log-v2-\(aScope.accountFileKey)-a.txt"],
                  "disk snapshot account isolation survives restart")
            check(aScope.accountFileKey != bScope.accountFileKey && aScope.scopeFileKey != bScope.scopeFileKey,
                  "opaque filenames include complete account identities")
        }

        print("RUNTIME_RECORDER_PASS \(checks) assertions (real recorder; controlled data only)")
    }
}

@main
struct RecorderMain {
    @MainActor static func main() {
        RecorderChecks.run()
    }
}
