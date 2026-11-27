import Foundation

/// Only opaque run/session IDs are retained; credentials and message text never enter this store.
@MainActor
final class GatewayRunStore {
    private let defaults: UserDefaults?
    private let key: String
    private let generationKey: String
    private let unresolvedKey: String
    private let terminalKey: String
    private let userReleasedKey: String
    private var userReleased: [String: [String]] = [:]
    private struct TerminalReceipt: Codable, Equatable {
        let runID: String
        let outcome: RunTerminalStatus
    }
    private var terminalReceipts: [String: TerminalReceipt] = [:]
    private var unresolved: [String: String]
    private let generation: String
    private var values: [String: String]

    /// F-55d：本轮 run 记录**写盘失败**。写失败意味着「不自动重发」的保证不再可靠，
    /// UI 需要据此提示「本轮恢复能力不可用」。
    ///
    /// 每次写入都按本次 `persist` 的结果重置（不是一旦置位就永久保留）：失败时
    /// `current()` 会切到内存真源，成功时切回磁盘，避免一次瞬时失败把本进程
    /// 永久钉在降级态。内存值本身始终正确，从不回滚。
    private(set) var persistenceFailed = false

    /// 失效诊断只写一次：`runID(for:)` 会被反复调用，逐次写 stderr 只会刷屏。
    private var didDiagnoseRetired = false

    init(scope: String?, defaults: UserDefaults = .standard) {
        self.defaults = scope == nil ? nil : defaults
        key = "HermesNative.gatewayRuns.v1." + (scope ?? "ephemeral")
        generationKey = "HermesNative.gatewayRunGeneration.v1." + (scope ?? "ephemeral")
        unresolvedKey = key + ".unresolved"
        terminalKey = key + ".terminals"
        userReleasedKey = key + ".userReleased"
        generation = defaults.string(forKey: generationKey) ?? UUID().uuidString
        if scope != nil { defaults.set(generation, forKey: generationKey) }
        values = scope == nil ? [:] : (defaults.dictionary(forKey: key) as? [String: String] ?? [:])
        unresolved = scope == nil ? [:] : (defaults.dictionary(forKey: unresolvedKey) as? [String: String] ?? [:])
    }

    /// F-72：`removeAll` 轮换 generation 之后，**已经存在的旧实例**会读到与自身
    /// `generation` 不同的值，于是失效并返回空记录。这是预期行为（防止旧账号的
    /// 迟到回调把记录复活），留一行诊断只是为了让排查时能看出「记录为什么没了」，
    /// 而不是把它当成一次数据丢失。
    private var isValid: Bool {
        defaults == nil || defaults?.string(forKey: generationKey) == generation
    }

    /// 读当前记录。
    ///
    /// 正常情况下磁盘是唯一真源：多实例（同一 scope 的两个 `GatewayRunStore`）靠
    /// 回读 `UserDefaults` 互相看见对方的写入，谁也不能拿自己那份旧内存覆盖别人。
    ///
    /// 但**写盘失败之后**磁盘是已知的坏数据（可能是旧值、也可能是 nil），此时必须
    /// 退回内存：`remember` 已经把正确值放进 `values`，若继续以磁盘为准，
    /// `runID(for:)` 会立刻返回 nil —— 「不自动重发」的保证在**当前进程内**就失效了，
    /// 这比「重启后恢复不了」严重得多。所以只在 `persistenceFailed` 时切换真源。
    ///
    /// 代价：写失败期间看不到同 scope 其他实例的更新。这是降级态的取舍——
    /// 记录已经不可持久化，优先保住本进程的正确性。
    private func current() -> [String: String] {
        guard isValid else {
            noteRetired()
            return [:]
        }
        if persistenceFailed { return values }
        if let defaults { return defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        return values
    }

    /// 失效只留一行诊断。
    ///
    /// 不用运行时日志记录器：本文件在 `tests/gatewaybackend` 里被单独编译，那个
    /// 套件没有链接日志模块。内容只含状态描述，不含任何 session/run/实例 id。
    /// 只写一次：`runID(for:)` 会被反复调用，逐次写 stderr 只会刷屏。
    private func noteRetired() {
        guard !didDiagnoseRetired else { return }
        didDiagnoseRetired = true
        Self.diagnose("run records unavailable: generation rotated, this scope instance is retired")
    }

    /// 写入后回读比对：`UserDefaults.set` 没有返回值，`synchronize()` 在 iOS 上也
    /// 不保证真正落盘，但能反映内存态是否已经一致。回读不一致就认为这次持久化
    /// 失败（F-55d / F-71）。
    private func persist(_ values: [String: String]) -> Bool {
        guard let defaults else { return true }
        defaults.set(values, forKey: key)
        // `synchronize()` 在 iOS 上不保证真正落盘，但能让内存态与磁盘态对齐后再回读。
        _ = defaults.synchronize()
        // 空字典回读可能是 nil（UserDefaults 不一定保留空容器），按空字典比较，
        // 否则「把所有记录清空」这一合法结果会被误判成写失败。
        let readBack = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return readBack == values
    }

    func runID(for sessionID: String) -> String? { current()[sessionID] }

    /// Mutation requires the exact live local owner, not just a plausible ID.
    func ownsUnknownResolutionCandidate(sessionID: String, runID: String) -> Bool {
        guard isValid, !persistenceFailed else { return false }
        let active = self.runID(for: sessionID)
        let retired = unresolvedRunID(for: sessionID)
        guard active == nil || active == runID, retired == nil || retired == runID else { return false }
        return active == runID || retired == runID
    }

    private func currentTerminals() -> [String: TerminalReceipt] {
        guard isValid else { return [:] }
        guard let defaults else { return terminalReceipts }
        guard let data = defaults.data(forKey: terminalKey) else { return [:] }
        return (try? JSONDecoder().decode([String: TerminalReceipt].self, from: data)) ?? [:]
    }

    private func persistTerminals(_ records: [String: TerminalReceipt]) -> Bool {
        guard isValid else { return false }
        guard let defaults else { terminalReceipts = records; return true }
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: terminalKey)
        return defaults.data(forKey: terminalKey) == data
    }

    func terminalOutcome(sessionID: String, runID: String) -> RunTerminalStatus? {
        guard isValid, runID == current()[sessionID] || current()[sessionID] == nil,
              unresolvedRunID(for: sessionID).map({ $0 == runID }) ?? true,
              let receipt = currentTerminals()[sessionID], receipt.runID == runID else { return nil }
        return receipt.outcome
    }

    func sessionID(owning runID: String) -> String? {
        let matches = current().filter { $0.value == runID }.keys
        return matches.count == 1 ? matches.first : nil
    }

    // Distinct from a terminal receipt. A person confirmed the old task
    // ended externally; the service still has no execution record.
    private func currentUserReleased() -> [String: [String]] {
        guard isValid else { return [:] }
        if let defaults { return defaults.dictionary(forKey: userReleasedKey) as? [String: [String]] ?? [:] }
        return userReleased
    }

    func wasUserReleased(sessionID: String, runID: String) -> Bool {
        currentUserReleased()[sessionID]?.contains(runID) == true
    }

    func canReleaseMissingRun(sessionID: String, runID: String) -> Bool {
        guard isValid, !persistenceFailed, !runID.isEmpty,
              self.runID(for: sessionID).map({ $0 == runID }) ?? true else { return false }
        let missing = unresolvedRunID(for: sessionID)
        guard missing == nil || missing == runID else { return false }
        return missing == runID || wasUserReleased(sessionID: sessionID, runID: runID)
    }

    @discardableResult
    func releaseMissingRun(sessionID: String, runID: String) -> Bool {
        guard canReleaseMissingRun(sessionID: sessionID, runID: runID) else { return false }
        var records = currentUserReleased()
        var released = records[sessionID] ?? []
        if !released.contains(runID) { released.append(runID) }
        // Per-session bounded local diagnostic fence, not a terminal status.
        records[sessionID] = Array(released.suffix(32))
        if let defaults {
            defaults.set(records, forKey: userReleasedKey)
            guard (defaults.dictionary(forKey: userReleasedKey) as? [String: [String]] ?? [:]) == records
            else { return false }
        } else { userReleased = records }
        if unresolvedRunID(for: sessionID) == runID,
           !clearUnresolved(runID: runID, sessionID: sessionID) { return false }
        if self.runID(for: sessionID) == runID { finish(runID: runID) }
        return !persistenceFailed
    }

    /// Preserve exact server evidence before retiring the active index.
    /// This is only a handoff to the protected model receipt, never proof
    /// of final transcript delivery or permission to send again.
    @discardableResult
    func recordTerminal(runID: String, sessionID: String, outcome: RunTerminalStatus) -> Bool {
        guard isValid, !wasUserReleased(sessionID: sessionID, runID: runID),
              current()[sessionID].map({ $0 == runID }) ?? true,
              unresolvedRunID(for: sessionID).map({ $0 == runID }) ?? true else { return false }
        var records = currentTerminals()
        if let old = records[sessionID], old.runID == runID, old.outcome != outcome { return false }
        records[sessionID] = TerminalReceipt(runID: runID, outcome: outcome)
        guard persistTerminals(records) else { persistenceFailed = true; return false }
        if unresolvedRunID(for: sessionID) == runID,
           !clearUnresolved(runID: runID, sessionID: sessionID) { return false }
        finish(runID: runID)
        return !persistenceFailed
    }

    func discardTerminal(sessionID: String) {
        var records = currentTerminals()
        guard records.removeValue(forKey: sessionID) != nil else { return }
        if !persistTerminals(records) { persistenceFailed = true }
    }

    /// An unresolved 404 is a durable diagnostic, not verified absence.
    func unresolvedRunID(for sessionID: String) -> String? {
        guard isValid else { return nil }
        if persistenceFailed { return unresolved[sessionID] }
        if let defaults {
            return (defaults.dictionary(forKey: unresolvedKey) as? [String: String])?[sessionID]
        }
        return unresolved[sessionID]
    }

    /// Drop the tombstone only after a fresh, exact-ID terminal response.
    /// A random later alive response never grants permission to resurrect.
    @discardableResult
    func clearUnresolved(runID: String, sessionID: String) -> Bool {
        guard isValid, unresolvedRunID(for: sessionID) == runID else { return false }
        var next = defaults?.dictionary(forKey: unresolvedKey) as? [String: String] ?? unresolved
        next.removeValue(forKey: sessionID)
        if let defaults {
            defaults.set(next, forKey: unresolvedKey)
            guard (defaults.dictionary(forKey: unresolvedKey) as? [String: String] ?? [:]) == next
            else { persistenceFailed = true; return false }
        }
        unresolved = next
        return true
    }

    /// Mark only the exact current Run unresolved. Persist the tombstone first,
    /// then retire its misleading running flag. A failed write stays fail-closed.
    @discardableResult
    func markUnresolved(runID: String, sessionID: String) -> Bool {
        guard isValid, current()[sessionID] == runID else { return false }
        var next = defaults?.dictionary(forKey: unresolvedKey) as? [String: String] ?? unresolved
        next[sessionID] = runID
        if let defaults {
            defaults.set(next, forKey: unresolvedKey)
            guard (defaults.dictionary(forKey: unresolvedKey) as? [String: String]) == next
            else { persistenceFailed = true; return false }
        }
        unresolved = next
        let remaining = current().filter { !($0.key == sessionID && $0.value == runID) }
        values = remaining
        persistenceFailed = !persist(remaining)
        return !persistenceFailed
    }

    /// Snapshot the run dictionary once for a whole session list. Calling
    /// runID(for:) once per row repeatedly materializes UserDefaults values.
    func runIDs(for sessionIDs: [String]) -> [String: String] {
        let snapshot = current()
        var found: [String: String] = [:]
        for sessionID in sessionIDs {
            if let runID = snapshot[sessionID] { found[sessionID] = runID }
        }
        return found
    }

    /// A durable model receipt can repair a lost local index after restart.
    /// Never overwrite a different Run, terminal, tombstone or user release.
    func restoreAcceptedRunIdentity(sessionID: String, runID: String) {
        guard isValid, !persistenceFailed, !runID.isEmpty,
              current()[sessionID] == nil, unresolvedRunID(for: sessionID) == nil,
              currentTerminals()[sessionID] == nil,
              !wasUserReleased(sessionID: sessionID, runID: runID) else { return }
        remember(runID: runID, sessionID: sessionID)
    }

    func remember(runID: String, sessionID: String) {
        guard isValid else { noteRetired(); return }
        // A delayed status response must not resurrect a 404-retired Run.
        if unresolvedRunID(for: sessionID) == runID ||
            wasUserReleased(sessionID: sessionID, runID: runID) { return }
        discardTerminal(sessionID: sessionID)
        values = current()
        values[sessionID] = runID
        // Active records are intentionally not expired by time: elapsed time cannot prove a run ended.
        // 内存值必须保持正确，写盘失败只置标记、不回滚。
        persistenceFailed = !persist(values)
        if !persistenceFailed, unresolvedRunID(for: sessionID) != nil {
            unresolved.removeValue(forKey: sessionID)
            if let defaults {
                var next = defaults.dictionary(forKey: unresolvedKey) as? [String: String] ?? [:]
                next.removeValue(forKey: sessionID)
                defaults.set(next, forKey: unresolvedKey)
            }
        }
    }

    func finish(runID: String) {
        guard isValid else { noteRetired(); return }
        values = current().filter { $0.value != runID }
        persistenceFailed = !persist(values)
    }

    /// 只写一行状态，不带任何会话/run 标识。
    private static func diagnose(_ message: String) {
        _ = try? FileHandle.standardError.write(contentsOf: Data(("[HermesNative][gateway-run] " + message + "\n").utf8))
    }

    static func removeAll(instanceID: String, accountScope: String? = nil,
                          defaults: UserDefaults = .standard) {
        let prefix = "HermesNative.gatewayRuns.v1." + instanceID + "|"
        let generationPrefix = "HermesNative.gatewayRunGeneration.v1." + instanceID + "|"
        if let accountScope {
            defaults.removeObject(forKey: prefix + accountScope)
            defaults.removeObject(forKey: prefix + accountScope + ".unresolved")
            defaults.removeObject(forKey: prefix + accountScope + ".terminals")
            defaults.removeObject(forKey: prefix + accountScope + ".userReleased")
            defaults.set(UUID().uuidString, forKey: generationPrefix + accountScope)
        } else {
            let keys = defaults.dictionaryRepresentation().keys
            let accounts = Set(keys.compactMap { key -> String? in
                if key.hasPrefix(prefix) { return String(key.dropFirst(prefix.count)) }
                if key.hasPrefix(generationPrefix) { return String(key.dropFirst(generationPrefix.count)) }
                return nil
            })
            for account in accounts {
                defaults.removeObject(forKey: prefix + account)
                defaults.removeObject(forKey: prefix + account + ".unresolved")
                defaults.removeObject(forKey: prefix + account + ".terminals")
                defaults.removeObject(forKey: prefix + account + ".userReleased")
                defaults.set(UUID().uuidString, forKey: generationPrefix + account)
            }
        }
    }
}
