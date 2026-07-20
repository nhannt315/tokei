import Foundation

/// One rate-limit bucket from the OAuth usage endpoint ("five_hour",
/// "seven_day", model-specific weekly caps, …). Rendered generically: the
/// endpoint's bucket list is authoritative, not a hardcoded pair.
public struct QuotaBucket: Sendable, Codable {
    public let key: String
    public let utilization: Double   // 0…1
    public let resetsAt: Date?

    public init(key: String, utilization: Double, resetsAt: Date?) {
        self.key = key
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct QuotaSnapshot: Sendable, Codable {
    public let buckets: [QuotaBucket]
    public let fetchedAt: Date

    public init(buckets: [QuotaBucket], fetchedAt: Date) {
        self.buckets = buckets
        self.fetchedAt = fetchedAt
    }

    public func bucket(_ key: String) -> QuotaBucket? {
        buckets.first { $0.key == key }
    }
}

public enum QuotaState: Sendable {
    case available(QuotaSnapshot)
    case noCredentials            // Keychain entry missing → "Sign in to Claude Code"
    case tokenExpired             // 401 → "Open Claude Code to refresh your session"
    case accessDenied             // user clicked Deny on the Keychain prompt
    case networkError(String)     // keep last snapshot, show staleness
}
