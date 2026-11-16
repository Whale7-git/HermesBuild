import Foundation

/// For WebUI, /api/session/new ignores the chosen model and provider. Model
/// selection is a second explicit operation whose effect must be verified
/// BEFORE an automatic first-turn POST can be armed. The caller already owns
/// the new Session ID, so failures can expose a recoverable orphan reference.
@MainActor
enum HomeModelActivation {
    enum Failure: LocalizedError {
        case unverified
        var errorDescription: String? {
            "服务端没有确认所选模型或 Provider，消息未自动发送。请核对新会话后手动继续。"
        }
    }

    static func confirmWebUI(backend: HermesBackend, sessionID: String,
                             option: ModelOption) async throws {
        try await backend.setSessionModel(sessionID: sessionID,
                                          model: option.model, provider: option.providerID)
        let snapshot = try await backend.history(sessionID: sessionID, before: nil)
        guard snapshot.sessionID == sessionID, snapshot.model == option.model else {
            throw Failure.unverified
        }
        if let provider = option.providerID, !provider.isEmpty {
            guard snapshot.modelProvider == provider else { throw Failure.unverified }
        }
    }
}
