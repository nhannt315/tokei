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

    /// The 5-hour session bucket, tolerating either endpoint alias.
    public var sessionBucket: QuotaBucket? { bucket("five_hour") ?? bucket("session") }

    /// The all-model weekly bucket, tolerating either endpoint alias.
    public var weeklyBucket: QuotaBucket? { bucket("seven_day") ?? bucket("weekly_all") }
}

extension QuotaBucket {
    /// Start of this bucket's window: `resetsAt - length`. A 5h session bucket
    /// resets 5h after it opened, so the window opened `resetsAt - 5h` ago.
    public func windowStart(length: TimeInterval, now: Date = Date()) -> Date? {
        guard let reset = resetsAt else { return nil }
        return reset.addingTimeInterval(-length)
    }

    /// Projected time this bucket reaches 100%, extrapolating the average fill
    /// rate since the window opened. `utilization` was 0 at `windowStart`, so
    /// rate = utilization / elapsed, and 100% lands at
    /// `windowStart + elapsed / utilization`. Nil when idle or already full.
    public func projectedLimit(windowStart: Date, now: Date = Date()) -> Date? {
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed > 0, utilization > 0, utilization < 1 else { return nil }
        return windowStart.addingTimeInterval(elapsed / utilization)
    }
}

public enum QuotaState: Sendable {
    case available(QuotaSnapshot)
    case noCredentials            // Keychain entry missing → "Sign in to Claude Code"
    case tokenExpired             // 401 → "Open Claude Code to refresh your session"
    case accessDenied             // user clicked Deny on the Keychain prompt
    case networkError(String)     // keep last snapshot, show staleness
}
