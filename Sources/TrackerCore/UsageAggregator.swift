import Foundation

/// Token totals for one bucket (day × model, session, …).
public struct TokenTotals: Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheCreate5m = 0
    public var cacheCreate1h = 0

    public init() {}

    public mutating func add(_ e: UsageEvent) {
        input += e.inputTokens
        output += e.outputTokens
        cacheRead += e.cacheReadTokens
        cacheCreate5m += e.cacheCreate5m
        cacheCreate1h += e.cacheCreate1h
    }

    public var total: Int { input + output + cacheRead + cacheCreate5m + cacheCreate1h }

    public mutating func merge(_ o: TokenTotals) {
        input += o.input
        output += o.output
        cacheRead += o.cacheRead
        cacheCreate5m += o.cacheCreate5m
        cacheCreate1h += o.cacheCreate1h
    }
}

/// Groups events by local-calendar day and model. Timestamps are UTC; day
/// bucketing uses the injected calendar (local by default) — the classic
/// off-by-one-day bug lives here, so the calendar is injectable for checks.
public struct UsageAggregator {
    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// startOfDay → model → totals
    public func byDayModel(_ events: [UsageEvent]) -> [Date: [String: TokenTotals]] {
        var out: [Date: [String: TokenTotals]] = [:]
        for e in events {
            let day = calendar.startOfDay(for: e.timestamp)
            out[day, default: [:]][e.model, default: TokenTotals()].add(e)
        }
        return out
    }

    /// model → totals for the day containing `now`.
    public func today(_ events: [UsageEvent], now: Date = Date()) -> [String: TokenTotals] {
        let day = calendar.startOfDay(for: now)
        return byDayModel(events)[day] ?? [:]
    }

    /// model → totals for the month containing `now`.
    public func thisMonth(_ events: [UsageEvent], now: Date = Date()) -> [String: TokenTotals] {
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return [:] }
        var out: [String: TokenTotals] = [:]
        for e in events where e.timestamp >= monthStart && e.timestamp <= now {
            out[e.model, default: TokenTotals()].add(e)
        }
        return out
    }
}
