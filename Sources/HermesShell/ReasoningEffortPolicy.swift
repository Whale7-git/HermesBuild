import Foundation

/// Request-scoped Hermes Gateway reasoning effort. The provider may reject an
/// effort level; the model directory has no per-model supported-effort field.
enum ReasoningEffortPolicy {
    static let levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static func validated(_ value: String?) -> String? {
        guard let value, levels.contains(value) else { return nil }
        return value
    }
    static func allowed(_ value: String?) -> Bool {
        value == nil || validated(value) != nil
    }
    static func preferenceKey(scope: String, sessionID: String) -> String {
        "hermes.reasoningEffort.v1.\(scope).\(sessionID)"
    }
}
