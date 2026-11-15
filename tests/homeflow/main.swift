import Foundation

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { print("FAIL: \(message)"); exit(1) }
}

expect(!HomeTurnPolicy.canSubmit(text: "  \n", creating: false, needsSetup: false),
       "whitespace-only home input does not create a server session")
expect(!HomeTurnPolicy.canSubmit(text: "hello", creating: true, needsSetup: false),
       "double taps during creation cannot open a second request")
expect(!HomeTurnPolicy.canSubmit(text: "hello", creating: false, needsSetup: true),
       "unconfigured backend cannot start a chat")
expect(HomeTurnPolicy.canSubmit(text: "你好", creating: false, needsSetup: false),
       "Unicode text is eligible for first-turn submission")
expect(HomeTurnPolicy.canStartAttachment(creating: false, needsSetup: false),
       "attachment can open a session without first sending blank content")
expect(!HomeTurnPolicy.canStartAttachment(creating: true, needsSetup: false),
       "attachment tap during session creation cannot race a second session")
expect(!HomeTurnPolicy.canStartAttachment(creating: false, needsSetup: true),
       "attachment cannot create an unconfigured remote session")
expect(HomeTurnPolicy.modelIsUnambiguous(nil, matchingCount: 0),
       "server default requires no model catalog")
expect(HomeTurnPolicy.modelIsUnambiguous("unique", matchingCount: 1),
       "single model identifier can be passed to create")
expect(!HomeTurnPolicy.modelIsUnambiguous("duplicate", matchingCount: 2),
       "same model name on two providers must not be guessed")
expect(!HomeTurnPolicy.modelIsUnambiguous("missing", matchingCount: 0),
       "stale model catalog selection is rejected")

let item = HomeTurnHandoff(instanceID: "instance-a", accountScope: "account-1",
                           sessionID: "session-99", text: "hello first")
var claimed = HomeTurnClaim()
claimed.arm(item)
expect(claimed.claim(instanceID: "instance-a", accountScope: "account-1",
                     sessionID: "session-99") == "hello first",
       "same instance/account/session claims the exact first message")
expect(claimed.claim(instanceID: "instance-a", accountScope: "account-1",
                     sessionID: "session-99") == nil,
       "a second mount cannot send the original POST again")
for (instance, account, session) in [
    ("instance-b", "account-1", "session-99"),
    ("instance-a", "account-2", "session-99"),
    ("instance-a", "account-1", "session-100")
] {
    claimed.arm(item)
    expect(claimed.claim(instanceID: instance, accountScope: account,
                         sessionID: session) == nil,
           "stale or cross-scope chat cannot claim first-turn text")
    expect(claimed.pending == nil,
           "identity mismatch burns the handoff, never retains it for a future view")
}
claimed.arm(item)
claimed.cancel()
expect(claimed.claim(instanceID: "instance-a", accountScope: "account-1",
                     sessionID: "session-99") == nil,
       "user navigation cancels a not-yet-delivered handoff")
claimed.arm(item)
claimed.arm(.init(instanceID: "instance-a", accountScope: "account-1",
                  sessionID: "session-100", text: "newest"))
expect(claimed.claim(instanceID: "instance-a", accountScope: "account-1",
                     sessionID: "session-99") == nil,
       "only the newest explicitly created session owns pending delivery")

print("HOME_FLOW_PASS \(checks) assertions")
