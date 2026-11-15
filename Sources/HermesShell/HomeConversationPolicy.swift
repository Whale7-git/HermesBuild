import Foundation

/// In-memory, exactly-once *client handoff* from an unsent home composer
/// to the existing session-owned NativeChatModel. This is not a server-side
/// idempotency guarantee. The session draft is persisted separately BEFORE
/// the handoff is armed, so app termination never causes an automatic replay.
struct HomeTurnHandoff: Equatable, Sendable {
    let instanceID: String
    let accountScope: String
    let sessionID: String
    let text: String
}

struct HomeTurnClaim {
    private(set) var pending: HomeTurnHandoff?

    mutating func arm(_ turn: HomeTurnHandoff) {
        pending = turn
    }

    /// Consume before entering any async/network send path. A mismatched
    /// identity fails closed rather than retaining a turn for a later view.
    mutating func claim(instanceID: String, accountScope: String,
                        sessionID: String) -> String? {
        guard let turn = pending else { return nil }
        pending = nil
        guard turn.instanceID == instanceID, turn.accountScope == accountScope,
              turn.sessionID == sessionID else { return nil }
        return turn.text
    }

    mutating func cancel() { pending = nil }
}

enum HomeTurnPolicy {
    static func canSubmit(text: String, creating: Bool, needsSetup: Bool) -> Bool {
        !creating && !needsSetup
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A creation API that accepts only the model name cannot disambiguate
    /// identical model IDs under different providers. Fail rather than silently
    /// using a different provider from the UI selection.
    static func modelIsUnambiguous(_ model: String?, matchingCount: Int) -> Bool {
        model == nil || matchingCount == 1
    }
}
