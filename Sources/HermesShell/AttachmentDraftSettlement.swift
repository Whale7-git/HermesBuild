import Foundation

extension ChatDraftStore {
    func consumeSettledAttachmentPaths(_ paths: Set<String>, sessionID: String) -> LocalStoreWriteResult {
        guard !paths.isEmpty else { return .ok }
        let loaded = loadAttachmentDraft()
        guard loaded.result.succeeded else { return loaded.result }
        guard let data = loaded.value else { return .ok }
        guard let batch = try? JSONDecoder().decode(PersistedAttachmentBatch.self, from: data),
              batch.version == PersistedAttachmentBatch.currentVersion,
              batch.sessionID == sessionID else { return .failed(.corruptFile) }
        let remaining = batch.removingSettledPaths(paths)
        guard remaining != batch else { return .ok }
        if remaining.items.isEmpty { return saveAttachmentDraft(nil) }
        guard let encoded = try? JSONEncoder().encode(remaining) else { return .failed(.encoding) }
        return saveAttachmentDraft(encoded)
    }
}
