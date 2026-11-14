import Foundation

enum CookieDomainPolicy {
    /// DNS suffixes must end at a label boundary. IP hosts require exact match.
    static func matches(_ domain: String, host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        guard !host.isEmpty, !domain.isEmpty else { return false }
        if host == domain { return true }
        let isIP = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        return !isIP && host.hasSuffix("." + domain)
    }
}
