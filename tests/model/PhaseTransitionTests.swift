import Foundation

/// 相位收敛后的回归网。
///
/// 这一组测试的目的不是「测 UI」，而是把原先散在 18 个布尔里的组合规则钉死成
/// 可执行断言。三个谓词（canSend / canSendWhileRunning / canResendPending）原先
/// 各写一遍否定条件，条数还不一样——这里用穷举把所有相位与正交事实的乘积跑一遍，
/// 任何一处漂移都会立刻失败。
extension ModelTests {
    @MainActor static func phaseTransitionTests() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1; precondition(condition(), label)
        }

        // MARK: 相位互斥：一次只有一个

        expect(ChatPhase.idle.isRunning == false && ChatPhase.idle.isLoading == false
               && ChatPhase.idle.isSyncing == false && ChatPhase.idle.isConnected == false,
               "idle is the only fully static phase")

        expect(ChatPhase.loading.isLoading && !ChatPhase.loading.isRunning,
               "loading is not running: the first frame has not arrived yet")
        expect(ChatPhase.syncing.isSyncing && !ChatPhase.syncing.isRunning,
               "silent sync keeps the conversation visible and is not running")
        expect(ChatPhase.submitting.isRunning && !ChatPhase.submitting.isConnected,
               "submitting is running but has no stream yet")
        expect(ChatPhase.stopping.isRunning, "stopping is still part of the same turn")
        expect(ChatPhase.reconnecting.isRunning && !ChatPhase.reconnecting.isConnected,
               "reconnecting is running: the server turn did not end, only the socket did")
        expect(ChatPhase.streaming(connected: false).isRunning
               && !ChatPhase.streaming(connected: false).isConnected,
               "streaming before the first frame is running but not connected")
        expect(ChatPhase.streaming(connected: true).isConnected,
               "streaming after a frame is connected")
        expect(ChatPhase.needsLogin.isRunning == false && ChatPhase.needsLogin.isConnected == false,
               "an expired session owns no stream")

        // 磁盘缓存：只读、非运行、可带 syncing 位
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let cachedIdle = ChatPhase.cached(savedAt: stamp, syncing: false)
        let cachedBusy = ChatPhase.cached(savedAt: stamp, syncing: true)
        expect(cachedIdle.isCached && !cachedIdle.isRunning && !cachedIdle.isSyncing,
               "cached without a network round trip is not syncing")
        expect(cachedBusy.isSyncing, "cached while verifying the network reports syncing")
        expect(cachedIdle.cachedSince == stamp && ChatPhase.idle.cachedSince == nil,
               "only the cached phase carries a disk timestamp")

        // MARK: 本轮修掉的真缺陷：重连期间不可 steer

        let facts = ChatFacts(readOnly: false, uncertain: false, suspended: false,
                              hasPendingSend: false, pendingAbsent: false,
                              sendingWhileRunning: false)
        expect(ChatPhase.reconnecting.allowsSteer(facts) == false,
               "steering during reconnect must be refused: the server has no live agent")
        expect(ChatPhase.streaming(connected: true).allowsSteer(facts),
               "steering an attached stream is allowed")
        expect(ChatPhase.streaming(connected: false).allowsSteer(facts),
               "steering before the first frame is still allowed: the run exists server-side")

        // 修复前 canSendWhileRunning 漏了 !reconnecting，这条断言会失败。
        expect(ChatPhase.reconnecting.allowsNewTurn(facts) == false,
               "a reconnecting turn is not a new turn either")

        // MARK: canSend 只在 idle 成立

        for phase in allPhases() {
            let allowed = phase.allowsNewTurn(facts)
            expect(allowed == (phase == .idle),
                   "only idle allows a new turn, got \(phase)")
        }

        // MARK: 正交事实逐个把三个谓词全部关掉

        let blockingFacts: [(String, ChatFacts)] = [
            ("readOnly", ChatFacts(readOnly: true, uncertain: false, suspended: false,
                                   hasPendingSend: false, pendingAbsent: false,
                                   sendingWhileRunning: false)),
            ("uncertain", ChatFacts(readOnly: false, uncertain: true, suspended: false,
                                    hasPendingSend: false, pendingAbsent: false,
                                    sendingWhileRunning: false)),
            ("suspended", ChatFacts(readOnly: false, uncertain: false, suspended: true,
                                    hasPendingSend: false, pendingAbsent: false,
                                    sendingWhileRunning: false)),
            ("hasPendingSend", ChatFacts(readOnly: false, uncertain: false, suspended: false,
                                         hasPendingSend: true, pendingAbsent: false,
                                         sendingWhileRunning: false)),
            ("sendingWhileRunning", ChatFacts(readOnly: false, uncertain: false, suspended: false,
                                              hasPendingSend: false, pendingAbsent: false,
                                              sendingWhileRunning: true)),
        ]
        for (name, blocking) in blockingFacts {
            for phase in allPhases() {
                expect(!phase.allowsNewTurn(blocking), "\(name) must block a new turn in \(phase)")
                expect(!phase.allowsSteer(blocking), "\(name) must block steering in \(phase)")
            }
        }

        // MARK: 重发要求 pendingAbsent 且仅 idle

        for phase in allPhases() {
            let resendable = phase.allowsResend(facts)
            expect(resendable == false, "resend needs pendingAbsent, got \(phase)")
        }
        var absent = facts
        absent.pendingAbsent = true
        absent.hasPendingSend = true
        expect(ChatPhase.idle.allowsResend(absent), "confirmed-absent send can be resent from idle")
        expect(!ChatPhase.streaming(connected: true).allowsResend(absent),
               "never resend while a turn is live")
        expect(!ChatPhase.reconnecting.allowsResend(absent),
               "never resend during reconnect: the POST may still land")
        var noPending = absent
        noPending.hasPendingSend = false
        expect(!ChatPhase.idle.allowsResend(noPending),
               "resend without a snapshot is a no-op and must be refused")

        // MARK: activity 优先级（既有断言依赖这个顺序）

        let model = NativeChatModel(sessionID: "phase", api: PhaseOnlyService())
        model.readOnly = false
        model.transition(to: .idle)
        expect(model.activity == .ready, "idle with a writable session is ready")
        model.transition(to: .reconnecting)
        expect(model.activity == .reconnecting, "reconnecting outranks ready")
        model.transition(to: .streaming(connected: false))
        expect(model.activity == .connecting, "an attached stream without frames says connecting")
        model.transition(to: .streaming(connected: true))
        expect(model.activity == .replying, "a connected stream says replying")
        model.transition(to: .stopping)
        expect(model.activity == .stopping, "stopping outranks the running turn")
        model.transition(to: .needsLogin)
        expect(model.activity == .needsLogin, "an expired session outranks everything")
        model.transition(to: .idle)
        // 暂停是与相位正交的事实，且优先级高于相位自身。
        model.transition(to: .streaming(connected: true))
        model.suspended = true
        expect(model.activity == .suspended, "suspension overrides a live turn")
        model.suspended = false
        // 只读会话：相位静止但后端说不可写。
        model.transition(to: .idle)
        model.readOnly = true
        expect(model.activity == .readOnly, "a read-only session reports read-only, not ready")

        // MARK: transition 幂等且不改动等价相位

        model.readOnly = false
        model.transition(to: .idle)
        model.transition(to: .idle)
        expect(model.phase == .idle, "transition to the same phase is a no-op")

        print("PHASE_PASS \(checks) assertions")
    }

    /// 所有不带关联值的相位（用于穷举谓词）。带关联值的单独按语义构造。
    static func allPhases() -> [ChatPhase] {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return [.idle,
                .cached(savedAt: stamp, syncing: false),
                .cached(savedAt: stamp, syncing: true),
                .loading, .syncing, .reconnecting, .submitting,
                .streaming(connected: false), .streaming(connected: true),
                .stopping, .needsLogin]
    }
}

/// 相位测试只读状态、不发请求：所有必需方法都直接失败，避免误触发网络路径。
/// `requiresAuthentication` / `steerNativeTurn` / `approveNativeTurn` /
/// 带附件的 `startNativeTurn` 走协议默认实现，这里不必重复声明。
private final class PhaseOnlyService: NativeChatService {
    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        throw URLError(.unsupportedURL)
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        throw URLError(.unsupportedURL)
    }
    func stopNativeTurn(streamID: String) async throws { throw URLError(.unsupportedURL) }
    func streamNativeTurn(streamID: String, lastEventID: String?,
                          onFrame: (SSEFrame) async throws -> Bool) async throws {
        throw URLError(.unsupportedURL)
    }
}
