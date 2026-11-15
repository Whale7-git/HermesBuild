import Foundation

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    if !value() { print("FAIL: \(label)"); exit(1) }
}
check(ReasoningEffortPolicy.allowed(nil), "nil leaves provider defaults alone")
for level in ReasoningEffortPolicy.levels {
    check(ReasoningEffortPolicy.validated(level) == level, "valid \(level)")
}
for invalid in ["", "HIGH", "maximum", "fast"] {
    check(!ReasoningEffortPolicy.allowed(invalid), "invalid options fail closed")
}
check(ReasoningEffortPolicy.preferenceKey(scope: "a|1", sessionID: "c")
      != ReasoningEffortPolicy.preferenceKey(scope: "b|1", sessionID: "c"),
      "instance-scoped preferences")
check(ReasoningEffortPolicy.preferenceKey(scope: "a|1", sessionID: "c")
      != ReasoningEffortPolicy.preferenceKey(scope: "a|2", sessionID: "c"),
      "account-scoped preferences")
check(ReasoningEffortPolicy.preferenceKey(scope: "a|1", sessionID: "c")
      != ReasoningEffortPolicy.preferenceKey(scope: "a|1", sessionID: "d"),
      "session-scoped preferences")
print("MODEL_EFFORT_PASS")
