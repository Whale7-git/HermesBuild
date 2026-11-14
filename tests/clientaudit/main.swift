import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}
for (domain, host, expected) in [
    ("example.com", "example.com", true), (".example.com", "a.example.com", true),
    ("EXAMPLE.COM", "A.Example.com", true), ("example.com", "badexample.com", false),
    ("a.example.com", "example.com", false), ("example.com.evil", "example.com", false),
    ("other.test", "example.com", false), ("", "example.com", false), ("example.com", "", false),
    ("192.168.50.10", "192.168.50.10", true), ("50.10", "192.168.50.10", false),
    ("::1", "[::1]", true), ("::1", "::2", false),
] { check(CookieDomainPolicy.matches(domain, host: host) == expected, "cookie label/IP boundary") }
for source in ["[]", "{\"sessions\":[]}", "{\"items\":[]}", "{\"data\":[]}"] {
    check((try? JSONDecoder().decode(SessionListEnvelope.self, from: Data(source.utf8)))?.sessions.isEmpty == true,
          "valid empty session list")
}
for source in ["{}", "{\"error\":\"not a session list\"}", "{\"sessions\":{}}", "null"] {
    check((try? JSONDecoder().decode(SessionListEnvelope.self, from: Data(source.utf8))) == nil,
          "malformed response must not be displayed as empty success")
}
print("CLIENT_AUDIT_PASS \(checks) assertions (real cookie/list decoding; no server calls)")
