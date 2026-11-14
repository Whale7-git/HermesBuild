import Foundation

/// Explicit test-only storage. The app's Linux implementation does not persist
/// plaintext secrets and is never replaced with this mock in production.
final class FixtureCredentials: InstanceCredentialStorage {
    enum Failure: Error { case fixture }
    var values: [String: String] = [:]
    var writes = 0
    var failWriteNumber: Int?
    var failReads = false
    var failRemoves = false
    func read(reference: String) throws -> String? {
        if failReads { throw Failure.fixture }
        return values[reference]
    }
    func write(_ value: String, reference: String) throws {
        writes += 1
        if writes == failWriteNumber { throw Failure.fixture }
        precondition(values[reference] == nil, "production transactions stage immutable references")
        values[reference] = value
    }
    func remove(reference: String) throws {
        if failRemoves { throw Failure.fixture }
        values.removeValue(forKey: reference)
    }
}

@main struct CredentialTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ why: String) { checks += 1; precondition(value, why) }
        let suite = "HermesCredentialTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FixtureCredentials()
        let first = HermesInstance(name: "first", baseURL: "https://first.invalid", backend: .gateway, apiKey: "legacy-fixture-A")
        let second = HermesInstance(name: "second", baseURL: "https://second.invalid", backend: .gateway, apiKey: "legacy-fixture-B")
        let legacy = try JSONEncoder().encode([first, second])
        defaults.set(legacy, forKey: "hermes.instances")
        let migrated = InstanceStore.loadResult(defaults: defaults, credentials: credentials)
        check(migrated.warning == nil && migrated.instances == [first, second], "legacy migration preserves complete runtime instances")
        let metadata = defaults.data(forKey: "hermes.instances")!
        let metadataText = String(decoding: metadata, as: UTF8.self)
        check(!metadataText.contains(first.apiKey) && !metadataText.contains(second.apiKey), "preferences contain no migrated API keys")
        check(metadataText.contains("credential_ref") && credentials.values.count == 2, "both keys reside in independent secure references")
        let writesAfterMigration = credentials.writes
        let reloaded = InstanceStore.loadResult(defaults: defaults, credentials: credentials)
        check(reloaded.instances == [first, second] && reloaded.warning == nil, "secure references hydrate the exact original instance identities")
        check(credentials.writes == writesAfterMigration, "loading migrated metadata never rotates or rewrites keys")

        // Stage an update to A, then fail staging B. Both original references and
        // metadata must remain usable; this cannot be guaranteed by in-place updates.
        var changedA = first; changedA.apiKey = "changed-fixture-A"
        var changedB = second; changedB.apiKey = "changed-fixture-B"
        credentials.failWriteNumber = credentials.writes + 2
        do {
            try InstanceStore.save([changedA, changedB], defaults: defaults, credentials: credentials)
            preconditionFailure("staging failure was swallowed")
        } catch { check(true, "a Keychain write failure reaches the caller") }
        check(defaults.data(forKey: "hermes.instances") == metadata, "failed multi-instance commit does not change existing metadata")
        check(Set(credentials.values.values) == Set([first.apiKey, second.apiKey]), "failed staging preserves original keys and reclaims new slots")
        check(InstanceStore.load(defaults: defaults, credentials: credentials) == [first, second], "old configuration still loads after partial staging failure")

        credentials.failWriteNumber = nil
        try InstanceStore.save([changedA, second], defaults: defaults, credentials: credentials)
        check(Set(credentials.values.values) == Set([changedA.apiKey, second.apiKey]), "successful key replacement retires only the obsolete key")
        check(InstanceStore.load(defaults: defaults, credentials: credentials) == [changedA, second], "key replacement commits metadata and credential together")

        // A metadata copy cannot use another instance's reference to read its key.
        let committed = defaults.data(forKey: "hermes.instances")!
        var rows = try JSONSerialization.jsonObject(with: committed) as! [[String: Any]]
        rows[1]["credential_ref"] = rows[0]["credential_ref"]
        defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "hermes.instances")
        let crossed = InstanceStore.loadResult(defaults: defaults, credentials: credentials)
        check(crossed.warning != nil && crossed.instances[1].apiKey.isEmpty, "a foreign instance reference is refused")
        check(crossed.instances[0].apiKey == changedA.apiKey, "an invalid foreign reference does not corrupt another instance")
        defaults.set(committed, forKey: "hermes.instances")

        // A temporarily locked Keychain must not overwrite references with blanks.
        credentials.failReads = true
        let locked = InstanceStore.loadResult(defaults: defaults, credentials: credentials)
        check(locked.warning != nil && locked.instances.allSatisfy { $0.apiKey.isEmpty }, "unreadable secure keys produce a visible warning")
        check(defaults.data(forKey: "hermes.instances") == committed, "failed reads do not erase stored references")
        credentials.failReads = false

        // Delete metadata first, then remove the obsolete secure slot. Failed
        // cleanup is explicit and retried after unlock without losing the survivor.
        credentials.failRemoves = true
        let warning = try InstanceStore.save([second], defaults: defaults, credentials: credentials)
        check(warning != nil, "failed secure deletion is reported as pending cleanup")
        check(InstanceStore.load(defaults: defaults, credentials: credentials) == [second], "deleting one instance preserves another instance's key")
        check(credentials.values.count == 2, "failed removal remains tracked for a later retry")
        credentials.failRemoves = false
        let cleaned = InstanceStore.loadResult(defaults: defaults, credentials: credentials)
        check(cleaned.warning == nil && credentials.values.values.first == second.apiKey && credentials.values.count == 1,
              "pending deletion is retried and removes only the obsolete instance key")

        let interruptedReference = first.id.uuidString + "/" + UUID().uuidString
        credentials.values[interruptedReference] = "interrupted-stage-fixture"
        defaults.set([interruptedReference], forKey: "hermes.credentials.pendingCleanup.v1")
        let afterInterruption = InstanceStore.loadResult(defaults: defaults, credentials: credentials)
        check(afterInterruption.instances == [second] && credentials.values[interruptedReference] == nil,
              "a pre-commit interrupted transaction reclaims its staged slot without touching live keys")

        // Legacy plaintext is removed only after every migration write succeeds.
        defaults.set(legacy, forKey: "hermes.instances")
        credentials.failWriteNumber = credentials.writes + 1
        let failedMigration = InstanceStore.loadResult(defaults: defaults, credentials: credentials)
        check(failedMigration.warning?.contains("可能仍保留明文") == true,
              "failed legacy migration warns that plaintext may remain until readback is proven")
        check(failedMigration.instances.count == 2, "failed migration keeps the instance list")
        check(failedMigration.instances.allSatisfy { $0.apiKey.isEmpty },
              "failed migration scrubs plaintext keys from memory (never keeps them)")
        // 关键安全断言：失败后 UserDefaults 里不能再有明文 apiKey。
        let scrubbed = defaults.data(forKey: "hermes.instances")
        check(scrubbed != legacy, "migration failure rewrites metadata to drop plaintext")
        if let scrubbed, let text = String(data: scrubbed, encoding: .utf8) {
            check(!text.contains(first.apiKey) && !text.contains(second.apiKey),
                  "persisted metadata after failure contains no plaintext apiKey")
        }

        // The scrub path is independently testable: every failure mode must say
        // that plaintext may remain, while only a successful exact readback may
        // claim that the preference copy was cleared.
        let scrubInput = [first, second]
        let encodedScrub = try JSONEncoder().encode(scrubInput.map { instance in
            var copy = instance
            copy.apiKey = ""
            return copy
        })
        let missingReadback = InstanceStore.scrubLegacyPlaintext(
            scrubInput, encode: { _ in encodedScrub }, write: { _ in }, read: { nil })
        check(missingReadback.contains("可能仍保留明文"), "missing readback cannot claim plaintext was cleared")

        let mismatchedReadback = InstanceStore.scrubLegacyPlaintext(
            scrubInput, encode: { _ in encodedScrub }, write: { _ in },
            read: { Data("different".utf8) })
        check(mismatchedReadback.contains("可能仍保留明文"), "mismatched readback cannot claim success")

        let corruptReadback = InstanceStore.scrubLegacyPlaintext(
            scrubInput, encode: { _ in encodedScrub }, write: { _ in },
            read: { Data("{".utf8) })
        check(corruptReadback.contains("可能仍保留明文"), "corrupt readback cannot claim success")

        let plaintextReadback = InstanceStore.scrubLegacyPlaintext(
            scrubInput, encode: { _ in legacy }, write: { _ in }, read: { legacy })
        check(plaintextReadback.contains("可能仍保留明文"), "readback containing legacy plaintext is rejected")

        let encodingFailure = InstanceStore.scrubLegacyPlaintext(
            scrubInput, encode: { _ in throw FixtureCredentials.Failure.fixture },
            write: { _ in preconditionFailure("write must not run after encoding fails") },
            read: { nil })
        check(encodingFailure.contains("可能仍保留明文"), "encoding failure cannot claim plaintext was cleared")
        check(!encodingFailure.contains(first.apiKey) && !encodingFailure.contains(second.apiKey),
              "migration warnings never include the secret values")

        let persistedBlankKey = try JSONSerialization.data(withJSONObject: [
            ["id": first.id.uuidString, "apiKey": ""]
        ])
        let encryptedReadback = InstanceStore.scrubLegacyPlaintext(
            scrubInput, encode: { _ in persistedBlankKey }, write: { _ in },
            read: { persistedBlankKey })
        check(encryptedReadback.contains("可能仍保留明文"),
              "unexpected metadata shape is rejected by the strict readback")

        let verifiedReadback = InstanceStore.scrubLegacyPlaintext(
            scrubInput, encode: { _ in encodedScrub }, write: { _ in },
            read: { encodedScrub })
        check(verifiedReadback.contains("已确认") && verifiedReadback.contains("可能仍保留明文")
              && !verifiedReadback.contains(first.apiKey),
              "exact preference readback reports verified removal while retaining the broader warning")
        let scrubbedRuntime = failedMigration.instances
        check(scrubbedRuntime.map(\.id) == scrubInput.map(\.id)
              && scrubbedRuntime.map(\.baseURL) == scrubInput.map(\.baseURL)
              && scrubbedRuntime.map(\.backend) == scrubInput.map(\.backend),
              "scrubbing clears only secrets and preserves instance identity and configuration")

        var missing = first; missing.apiKey = ""
        let missingMetadata = try JSONEncoder().encode([missing])
        defaults.set(missingMetadata, forKey: "hermes.instances")
        let missingResult = InstanceStore.loadResult(defaults: defaults, credentials: credentials)
        check(missingResult.warning != nil && missingResult.instances.first?.id == first.id,
              "restored metadata without a secure reference requests credential repair")
        check(defaults.data(forKey: "hermes.instances") == missingMetadata, "missing credentials never rewrite metadata")

        #if !canImport(Security)
        do { try InstanceCredentialStore().write("fixture", reference: "fixture"); preconditionFailure("plaintext production fallback") }
        catch InstanceCredentialError.unavailable { check(true, "non-Apple production storage is explicitly unavailable") }
        #endif
        print("INSTANCE_CREDENTIALS_PASS \(checks) assertions; injectable Keychain mock, no production credentials")
    }
}
