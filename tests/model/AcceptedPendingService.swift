import Foundation

/// Controls a POST that is accepted after the chat view leaves and re-enters.
/// This double tests ordering only; it is never described as a real API call.
@MainActor final class AcceptedPendingService: NativeChatService {
    var pending: CheckedContinuation<String, Error>?
    var accepted = false
    func history(sessionID: String, before: Int?) async throws -> ChatSnapshot {
        var session: [String: Any] = ["session_id": sessionID, "messages": [], "read_only": false]
        if accepted {
            session["messages"] = [["id": "accepted-user", "role": "user", "content": "accepted"]]
            session["active_stream_id"] = "accepted-stream"
        }
        return try ChatSnapshot(data: JSONSerialization.data(withJSONObject: ["session": session]))
    }
    func startNativeTurn(sessionID: String, text: String) async throws -> String {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func streamNativeTurn(streamID: String, lastEventID: String?, onFrame: (SSEFrame) async throws -> Bool) async throws {
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
    func stopNativeTurn(streamID: String) async throws {}
}
