import Foundation

/// A successful model-change HTTP response is only an acknowledgement of
/// the request. Only an independent history snapshot with the exact session,
/// model and (when selected) provider may authorize local confirmation.
/// This pure check is shared by ordinary model changes and WebUI first-turn
/// setup; neither path may issue or replay a chat POST here.
enum SessionModelConfirmation {
    enum Failure: LocalizedError {
        case sessionMismatch
        case modelMismatch
        case providerUnavailable
        case providerMismatch

        var errorDescription: String? {
            switch self {
            case .sessionMismatch:
                return "模型切换待核对：服务端返回了其他会话的历史；未更新本地模型。"
            case .modelMismatch:
                return "模型切换待核对：服务端历史中的模型与所选模型不一致；未更新本地模型。"
            case .providerUnavailable:
                return "模型切换待核对：服务端历史没有提供 Provider 身份；未更新本地模型，请手动刷新核对。"
            case .providerMismatch:
                return "模型切换待核对：服务端确认的 Provider 与所选 Provider 不一致；未更新本地模型。"
            }
        }
    }

    static func verify(_ snapshot: ChatSnapshot, sessionID: String,
                       option: ModelOption) throws {
        guard snapshot.sessionID == sessionID else { throw Failure.sessionMismatch }
        guard snapshot.model == option.model else { throw Failure.modelMismatch }
        if let provider = option.providerID, !provider.isEmpty {
            guard let actual = snapshot.modelProvider, !actual.isEmpty else {
                throw Failure.providerUnavailable
            }
            guard actual == provider else { throw Failure.providerMismatch }
        }
    }
}

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
        do {
            try SessionModelConfirmation.verify(snapshot, sessionID: sessionID, option: option)
        } catch {
            throw Failure.unverified
        }
    }
}
