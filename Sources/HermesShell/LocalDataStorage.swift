import Foundation

#if os(Linux)
import Glibc
#endif

/// A local persistence failure category. It never contains message text,
/// account identifiers, endpoints or file paths, so it is safe to surface in
/// diagnostics and the recovery center.
enum LocalStoreWriteFailure: String, Error, Equatable, Sendable {
    case encoding
    case payloadTooLarge
    case diskWrite
    case backupProtection
    case corruptFile
}

struct LocalStoreWriteResult: Equatable, Sendable {
    let failure: LocalStoreWriteFailure?

    static let ok = LocalStoreWriteResult(failure: nil)
    var succeeded: Bool { failure == nil }

    static func failed(_ failure: LocalStoreWriteFailure) -> LocalStoreWriteResult {
        LocalStoreWriteResult(failure: failure)
    }
}

enum LocalDataKind: String, CaseIterable, Hashable, Sendable {
    case draft
    case queue
    case historyCache
    case runRecovery
}

struct LocalDataIssue: Equatable, Sendable {
    let kind: LocalDataKind
    let failure: LocalStoreWriteFailure
    let observedAt: Date
}

/// Atomic, protected storage for data that must survive process termination.
///
/// The envelope carries opaque scope digests so a copied or renamed file cannot
/// be read as another account's draft. Every successful write is read back and
/// byte-compared before the caller is told that persistence succeeded.
struct LocalDataFileStore: Sendable {
    typealias DestinationReadBackVerifier = @Sendable (_ url: URL, _ expected: Data) -> Bool

    struct Statistics: Equatable, Sendable {
        let files: Int
        let payloadBytes: Int64
        let corruptFiles: Int
        var directoryUnreadable = false

        var isHealthy: Bool { corruptFiles == 0 && !directoryUnreadable }
    }

    private struct Envelope: Codable {
        let version: Int
        let scopeHash: String
        let namespaceHash: String
        let payload: Data
    }

    private enum Loaded<T> {
        case missing
        case value(T)
        case invalid
    }

    private static let version = 1
    private static let maxDraftBytes = 2 * 1024 * 1024
    private static let maxQueueBytes = 16 * 1024 * 1024
    private static let maxActiveRunBytes = 128 * 1024
    static let maxCheckpointBytes = 4 * 1024 * 1024
    private static let maxAttachmentDraftBytes = 48 * 1024 * 1024

    let root: URL
    let scopeHash: String
    let namespaceHash: String
    private let sessionID: String
    private let destinationReadBackVerifier: DestinationReadBackVerifier

    init(instanceID: String, accountScope: String, sessionID: String,
         rootDirectory: URL = LocalDataFileStore.defaultRoot,
         destinationReadBackVerifier: @escaping DestinationReadBackVerifier = {
             url, expected in (try? Data(contentsOf: url)) == expected
         }) {
        root = rootDirectory
        self.sessionID = sessionID
        scopeHash = Self.digest([instanceID, accountScope, sessionID])
        namespaceHash = Self.digest([instanceID, accountScope])
        self.destinationReadBackVerifier = destinationReadBackVerifier
    }

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HermesNativeLocal-v1", isDirectory: true)
    }

    var draftURL: URL {
        root.appendingPathComponent("draft-\(namespaceHash)-\(scopeHash).json")
    }
    var queueURL: URL {
        root.appendingPathComponent("queue-\(namespaceHash)-\(scopeHash).json")
    }

    var pendingURL: URL {
        root.appendingPathComponent("pending-\(namespaceHash)-\(scopeHash).json")
    }

    /// Account/session-scoped accepted-run receipt. Never use UserDefaults in
    /// production: this uses the same protected, atomic envelope as PendingSend.
    var activeRunURL: URL {
        root.appendingPathComponent("active-run-\(namespaceHash)-\(scopeHash).json")
    }

    var recoveryIndexURL: URL {
        root.appendingPathComponent("recovery-index-\(namespaceHash)-\(scopeHash).json")
    }

    /// The protected discovery marker precedes either kind of receipt. A
    /// crash between the marker and receipt is harmless; a receipt can never
    /// become undiscoverable because a UI observation has not been published.
    private func ensureRecoveryIndex() -> LocalStoreWriteResult {
        let value = Data(sessionID.utf8)
        if case .value(let existing) = loadData(recoveryIndexURL, maxBytes: 16 * 1024),
           existing == value { return .ok }
        return save(value, to: recoveryIndexURL, maxBytes: 16 * 1024)
    }

    private func removeRecoveryIndexIfSettled() {
        let pending = loadPending(), accepted = loadActiveRun()
        if pending.result.succeeded, accepted.result.succeeded,
           pending.value == nil, accepted.value == nil {
            _ = remove(recoveryIndexURL)
        }
    }

    struct RecoveryIndexInspection: Equatable, Sendable {
        var sessions: Set<String> = []
        var directoryUnreadable = false
        var corruptMarkers = 0
        var isHealthy: Bool { !directoryUnreadable && corruptMarkers == 0 }
    }

    static func recoverySessions(instanceID: String, accountScope: String,
                                 rootDirectory: URL = defaultRoot) -> Set<String> {
        inspectRecoverySessions(instanceID: instanceID, accountScope: accountScope,
                                rootDirectory: rootDirectory).sessions
    }

    /// Missing storage on first launch is normal; an unreadable directory or
    /// invalid marker is not an authoritative empty recovery set.
    static func inspectRecoverySessions(instanceID: String, accountScope: String,
                                        rootDirectory: URL = defaultRoot) -> RecoveryIndexInspection {
        let namespace = digest([instanceID, accountScope])
        let prefix = "recovery-index-\(namespace)-"
        var result = RecoveryIndexInspection()
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) &&
                !FileManager.default.fileExists(atPath: rootDirectory.path) {
                return result
            }
            result.directoryUnreadable = true
            return result
        }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let url = rootDirectory.appendingPathComponent(name)
            guard let envelope = readEnvelope(url, maxBytes: 16 * 1024),
                  envelope.version == version, envelope.namespaceHash == namespace,
                  let session = String(data: envelope.payload, encoding: .utf8), !session.isEmpty else {
                result.corruptMarkers += 1
                continue
            }
            let store = LocalDataFileStore(instanceID: instanceID, accountScope: accountScope,
                sessionID: session, rootDirectory: rootDirectory)
            guard name == store.recoveryIndexURL.lastPathComponent,
                  envelope.scopeHash == store.scopeHash else {
                result.corruptMarkers += 1
                continue
            }
            if FileManager.default.fileExists(atPath: store.pendingURL.path) ||
                FileManager.default.fileExists(atPath: store.activeRunURL.path) {
                result.sessions.insert(session)
            }
        }
        return result
    }

    var outcomeURL: URL {
        root.appendingPathComponent("run-outcome-\(namespaceHash)-\(scopeHash).json")
    }

    func loadRunOutcome() -> (value: Data?, result: LocalStoreWriteResult) {
        switch loadData(outcomeURL, maxBytes: 128 * 1024) {
        case .missing: return (nil, .ok)
        case .value(let data): return (data, .ok)
        case .invalid: return (nil, .failed(.corruptFile))
        }
    }

    func saveRunOutcome(_ value: Data?) -> LocalStoreWriteResult {
        guard let value else { return remove(outcomeURL) }
        return save(value, to: outcomeURL, maxBytes: 128 * 1024)
    }

    var checkpointURL: URL {
        root.appendingPathComponent("checkpoint-\(namespaceHash)-\(scopeHash).json")
    }

    func loadCheckpoint() -> (value: Data?, result: LocalStoreWriteResult) {
        switch loadData(checkpointURL, maxBytes: Self.maxCheckpointBytes) {
        case .missing: return (nil, .ok)
        case .value(let data): return (data, .ok)
        case .invalid: return (nil, .failed(.corruptFile))
        }
    }

    func saveCheckpoint(_ value: Data?) -> LocalStoreWriteResult {
        guard let value else { return remove(checkpointURL) }
        return save(value, to: checkpointURL, maxBytes: Self.maxCheckpointBytes)
    }

    var attachmentDraftURL: URL {
        root.appendingPathComponent("attachments-\(namespaceHash)-\(scopeHash).json")
    }

    func loadActiveRun() -> (value: Data?, result: LocalStoreWriteResult) {
        switch loadData(activeRunURL, maxBytes: Self.maxActiveRunBytes) {
        case .missing: return (nil, .ok)
        case .value(let value): return (value, .ok)
        case .invalid: return (nil, .failed(.corruptFile))
        }
    }

    func saveActiveRun(_ value: Data?) -> LocalStoreWriteResult {
        guard let value else {
            let result = remove(activeRunURL)
            if result.succeeded { removeRecoveryIndexIfSettled() }
            return result
        }
        let index = ensureRecoveryIndex()
        guard index.succeeded else { return index }
        return save(value, to: activeRunURL, maxBytes: Self.maxActiveRunBytes)
    }

    func loadAttachmentDraft() -> (value: Data?, result: LocalStoreWriteResult) {
        switch loadData(attachmentDraftURL, maxBytes: Self.maxAttachmentDraftBytes) {
        case .missing: return (nil, .ok)
        case .value(let value): return (value, .ok)
        case .invalid: return (nil, .failed(.corruptFile))
        }
    }

    func saveAttachmentDraft(_ value: Data?) -> LocalStoreWriteResult {
        guard let value else { return remove(attachmentDraftURL) }
        return save(value, to: attachmentDraftURL, maxBytes: Self.maxAttachmentDraftBytes)
    }

    func loadPending() -> (value: Data?, result: LocalStoreWriteResult) {
        switch loadData(pendingURL, maxBytes: Self.maxQueueBytes) {
        case .missing: return (nil, .ok)
        case .value(let value): return (value, .ok)
        case .invalid: return (nil, .failed(.corruptFile))
        }
    }

    func savePending(_ value: Data?) -> LocalStoreWriteResult {
        guard let value else {
            let result = remove(pendingURL)
            if result.succeeded { removeRecoveryIndexIfSettled() }
            return result
        }
        let index = ensureRecoveryIndex()
        guard index.succeeded else { return index }
        return save(value, to: pendingURL, maxBytes: Self.maxQueueBytes)
    }

    func loadDraft() -> (value: String?, result: LocalStoreWriteResult) {
        switch loadString(draftURL, maxBytes: Self.maxDraftBytes) {
        case .missing:
            return (nil, .ok)
        case .value(let value):
            return (value, .ok)
        case .invalid:
            return (nil, .failed(.corruptFile))
        }
    }

    func loadQueue() -> (value: Data?, result: LocalStoreWriteResult) {
        switch loadData(queueURL, maxBytes: Self.maxQueueBytes) {
        case .missing:
            return (nil, .ok)
        case .value(let value):
            return (value, .ok)
        case .invalid:
            return (nil, .failed(.corruptFile))
        }
    }

    /// Re-read both persisted files so the recovery center can distinguish a
    /// healthy store from a stale in-memory failure without exposing content.
    func validate() -> LocalStoreWriteResult {
        let draft = loadDraft().result
        if !draft.succeeded { return draft }
        let queue = loadQueue().result
        if !queue.succeeded { return queue }
        let active = loadActiveRun().result
        return active.succeeded ? loadAttachmentDraft().result : active
    }

    func saveDraft(_ value: String) -> LocalStoreWriteResult {
        guard let data = value.data(using: .utf8) else {
            return .failed(.encoding)
        }
        return save(data, to: draftURL, maxBytes: Self.maxDraftBytes)
    }

    func saveQueue(_ value: Data?) -> LocalStoreWriteResult {
        guard let value else { return remove(queueURL) }
        return save(value, to: queueURL, maxBytes: Self.maxQueueBytes)
    }

    func removeDraft() -> LocalStoreWriteResult { remove(draftURL) }

    func remove() -> LocalStoreWriteResult {
        let first = remove(draftURL)
        let second = remove(queueURL)
        let third = remove(pendingURL)
        let fourth = remove(activeRunURL)
        let fifth = remove(attachmentDraftURL)
        let sixth = remove(checkpointURL)
        let seventh = remove(recoveryIndexURL)
        let eighth = remove(outcomeURL)
        if !first.succeeded { return first }
        if !second.succeeded { return second }
        if !third.succeeded { return third }
        if !fourth.succeeded { return fourth }
        if !fifth.succeeded { return fifth }
        if !sixth.succeeded { return sixth }
        return seventh.succeeded ? eighth : seventh
    }

    static func removeAll(instanceID: String, accountScope: String,
                          rootDirectory: URL) -> LocalStoreWriteResult {
        let target = digest([instanceID, accountScope])
        let manager = FileManager.default
        guard manager.fileExists(atPath: rootDirectory.path) else { return .ok }
        // swift-corelibs-foundation on Linux may return [] when enumerating a
        // regular file with the URL-based API. The path-based API correctly
        // throws ENOTDIR; never report an existing invalid root as cleaned.
        do {
            _ = try manager.contentsOfDirectory(atPath: rootDirectory.path)
        } catch {
            return .failed(.diskWrite)
        }
        guard let urls = try? manager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return .failed(.diskWrite) }
        var failure: LocalStoreWriteFailure?
        for url in urls where Self.belongs(url, to: target) {
            do {
                try manager.removeItem(at: url)
            } catch {
                failure = .diskWrite
            }
        }
        return failure.map(LocalStoreWriteResult.failed) ?? .ok
    }

    static func statistics(instanceID: String, accountScope: String,
                           rootDirectory: URL) -> Statistics {
        let target = digest([instanceID, accountScope])
        let manager = FileManager.default
        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: rootDirectory.path)
        } catch {
            return Statistics(files: 0, payloadBytes: 0, corruptFiles: 0,
                              directoryUnreadable: !isMissingFile(error))
        }
        var files = 0
        var bytes: Int64 = 0
        var corrupt = 0
        for name in names where name.hasSuffix(".json") {
            let url = rootDirectory.appendingPathComponent(name)
            guard Self.belongs(url, to: target) else { continue }
            // Apply the same payload budget as the owning record type. A
            // valid attachment draft can be larger than the queue limit.
            guard let limit = statisticsLimit(name: name, namespace: target),
                  let envelope = readEnvelope(url, maxBytes: limit),
                  envelope.version == version, envelope.namespaceHash == target,
                  name.hasSuffix("-" + envelope.scopeHash + ".json") else {
                corrupt += 1
                continue
            }
            files += 1
            bytes += Int64(envelope.payload.count)
        }
        return Statistics(files: files, payloadBytes: bytes, corruptFiles: corrupt)
    }

    private static func statisticsLimit(name: String, namespace: String) -> Int? {
        let types: [(String, Int)] = [
            ("draft", maxDraftBytes), ("queue", maxQueueBytes), ("pending", maxQueueBytes),
            ("active-run", maxActiveRunBytes), ("attachments", maxAttachmentDraftBytes),
            ("checkpoint", maxCheckpointBytes), ("recovery-index", 16 * 1024),
            ("run-outcome", 128 * 1024)
        ]
        return types.first { name.hasPrefix($0.0 + "-" + namespace + "-") }?.1
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain &&
            (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError)
    }

    private func save(_ payload: Data, to url: URL, maxBytes: Int) -> LocalStoreWriteResult {
        guard payload.count <= maxBytes else { return .failed(.payloadTooLarge) }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed(.diskWrite)
        }
        var directoryURL = directory
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        #if os(iOS)
        do {
            try directoryURL.setResourceValues(excluded)
        } catch {
            return .failed(.backupProtection)
        }
        #else
        try? directoryURL.setResourceValues(excluded)
        #endif

        let envelope = Envelope(version: Self.version, scopeHash: scopeHash,
                                namespaceHash: namespaceHash, payload: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(envelope) else {
            return .failed(.encoding)
        }
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        let backup = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).backup")
        var keepBackup = false
        var previousEncoded: Data?
        defer {
            if !keepBackup { try? manager.removeItem(at: backup) }
        }
        do {
            #if os(iOS)
            try encoded.write(to: temporary, options: [.completeFileProtection])
            var temporaryURL = temporary
            try temporaryURL.setResourceValues(excluded)
            #else
            try encoded.write(to: temporary, options: [])
            #endif
            // Verify the complete envelope before either the destination or its
            // backup is touched. A failed temporary write cannot invalidate the
            // previously committed value.
            guard let temporaryReadBack = try? Data(contentsOf: temporary),
                  temporaryReadBack == encoded,
                  Self.readEnvelope(temporary, maxBytes: maxBytes)?.scopeHash == scopeHash else {
                return .failed(.diskWrite)
            }
            let hadExistingValue = manager.fileExists(atPath: url.path)
            if hadExistingValue { previousEncoded = try Data(contentsOf: url) }
            if let existing = previousEncoded {
                // Keep a verified same-directory copy until the new destination
                // has passed read-back. If rollback itself fails, retain the
                // backup rather than deleting the last good copy. A malformed
                // destination has no good value to roll back to; allowing the
                // verified replacement to repair it is the recovery path.
                if Self.readEnvelope(url, maxBytes: maxBytes)?.scopeHash == scopeHash {
                    try manager.copyItem(at: url, to: backup)
                    guard let backupReadBack = try? Data(contentsOf: backup),
                          backupReadBack == existing,
                          Self.readEnvelope(backup, maxBytes: maxBytes)?.scopeHash == scopeHash else {
                        return .failed(.diskWrite)
                    }
                } else {
                    previousEncoded = nil
                }
            }
            #if os(Linux)
            // swift-corelibs-foundation replaceItemAt can unlink the destination
            // and then fail with ENOENT on Linux. The temporary file is created
            // in the same directory, so POSIX rename is atomic and overwrites.
            guard Glibc.rename(temporary.path, url.path) == 0 else {
                return .failed(.diskWrite)
            }
            #else
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            #endif
            // The guarantee is "persisted and readable", not "write() returned".
            let committedData = try? Data(contentsOf: url)
            let committedEnvelope = Self.readEnvelope(url, maxBytes: maxBytes)
            guard let committedData, let committedEnvelope,
                  committedEnvelope.scopeHash == scopeHash,
                  destinationReadBackVerifier(url, committedData) else {
                if let previousEncoded {
                    if !Self.restoreCommittedValue(
                        previousEncoded, to: url, directory: directory) {
                        keepBackup = Self.preserveBackup(backup, for: url, in: directory)
                    }
                } else {
                    try? manager.removeItem(at: url)
                }
                return .failed(.diskWrite)
            }
            return .ok
        } catch {
            if let previousEncoded {
                // A filesystem error after replacement (for example while
                // checking protection attributes) still must not consume the
                // last committed value. Restore it when possible and leave the
                // backup behind when the filesystem cannot complete the rollback.
                if !Self.restoreCommittedValue(
                    previousEncoded, to: url, directory: directory) {
                    // `backup` has its own defer cleanup. Preserve it explicitly
                    // by moving it to a stable recovery name before returning.
                    keepBackup = Self.preserveBackup(backup, for: url, in: directory)
                }
            }
            return .failed(.diskWrite)
        }
    }

    private static func preserveBackup(_ backup: URL, for url: URL, in directory: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: backup.path) else { return false }
        let recovery = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).recovery")
        do {
            try manager.moveItem(at: backup, to: recovery)
            return true
        } catch {
            // If moving fails, leave `backup` in place so the outer defer can
            // preserve it rather than deleting the last readable copy.
            return true
        }
    }


    /// Restore a previously verified envelope without ever writing directly to
    /// the live path. The caller has already retained the old bytes in memory;
    /// the extra on-disk backup is only for process/filesystem failure diagnosis.
    private static func restoreCommittedValue(
        _ value: Data, to url: URL, directory: URL
    ) -> Bool {
        let manager = FileManager.default
        let restore = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).restore")
        defer { try? manager.removeItem(at: restore) }
        do {
            try value.write(to: restore, options: [])
            guard (try? Data(contentsOf: restore)) == value else { return false }
            #if os(Linux)
            guard Glibc.rename(restore.path, url.path) == 0 else { return false }
            #else
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: restore)
            } else {
                try manager.moveItem(at: restore, to: url)
            }
            #endif
            return (try? Data(contentsOf: url)) == value
        } catch {
            return false
        }
    }

    private func remove(_ url: URL) -> LocalStoreWriteResult {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return .ok
        } catch {
            return .failed(.diskWrite)
        }
    }

    private func loadString(_ url: URL, maxBytes: Int) -> Loaded<String> {
        switch loadData(url, maxBytes: maxBytes) {
        case .missing: return .missing
        case .invalid: return .invalid
        case .value(let data):
            guard let value = String(data: data, encoding: .utf8) else { return .invalid }
            return .value(value)
        }
    }

    private func loadData(_ url: URL, maxBytes: Int) -> Loaded<Data> {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            // A locked/unreadable directory is not proof that an original
            // POST record is missing. Only classify a real missing path.
            guard Self.isMissingFile(error) else { return .invalid }
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
                return .missing
            } catch {
                return Self.isMissingFile(error) ? .missing : .invalid
            }
        }
        guard let envelope = Self.readEnvelope(url, maxBytes: maxBytes),
              envelope.version == Self.version,
              envelope.scopeHash == scopeHash,
              envelope.namespaceHash == namespaceHash else { return .invalid }
        return .value(envelope.payload)
    }

    private static func readEnvelope(_ url: URL, maxBytes: Int) -> Envelope? {
        // Base64 plus JSON escaping is bounded by three times payload size
        // and fixed envelope metadata. Check before allocating or decoding.
        let encodedLimit = maxBytes * 3 + 4096
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= Int64(encodedLimit),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: encodedLimit + 1),
              data.count <= encodedLimit,
              let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.payload.count <= maxBytes else { return nil }
        return value
    }

    private static func belongs(_ url: URL, to namespaceHash: String) -> Bool {
        let name = url.lastPathComponent
        let prefix = "draft-\(namespaceHash)-"
        let queuePrefix = "queue-\(namespaceHash)-"
        return name.hasPrefix(prefix) || name.hasPrefix(queuePrefix)
            || name.hasPrefix("pending-\(namespaceHash)-")
            || name.hasPrefix("active-run-\(namespaceHash)-")
            || name.hasPrefix("attachments-\(namespaceHash)-")
            || name.hasPrefix("checkpoint-\(namespaceHash)-")
            || name.hasPrefix("recovery-index-\(namespaceHash)-")
            || name.hasPrefix("run-outcome-\(namespaceHash)-")
    }

    private static func digest(_ components: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(components)) ?? Data()
        var first: UInt64 = 14695981039346656037
        var second: UInt64 = 7809847782465536322
        for byte in bytes {
            first = (first ^ UInt64(byte)) &* 1099511628211
            second = (second ^ UInt64(byte)) &* 14029467366897019727
        }
        return String(format: "%016llx%016llx", first, second)
    }
}
