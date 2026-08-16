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

    /// project slug → model → totals, over `[start, now]`. Slug is the
    /// `~/.claude/projects/<slug>/` folder; extracted from each event's path.
    public func byProject(_ events: [UsageEvent],
                          since start: Date, now: Date = Date()) -> [String: [String: TokenTotals]] {
        var out: [String: [String: TokenTotals]] = [:]
        for e in events where e.timestamp >= start && e.timestamp <= now {
            let project = Self.projectSlug(from: e.sessionPath)
            out[project, default: [:]][e.model, default: TokenTotals()].add(e)
        }
        return out
    }

    /// startOfDay → merged totals, for the N days ending on `now`'s day
    /// (oldest first). Days with no activity are present with zero totals so
    /// charts render a continuous axis.
    public func lastDays(_ events: [UsageEvent], count: Int, now: Date = Date()) -> [(day: Date, totals: TokenTotals)] {
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: TokenTotals] = [:]
        for e in events {
            let day = calendar.startOfDay(for: e.timestamp)
            byDay[day, default: TokenTotals()].add(e)
        }
        return (0..<count).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, byDay[day] ?? TokenTotals())
        }
    }

    /// Week-start → merged totals, for the N weeks ending on `now`'s week
    /// (oldest first). Empty weeks included as zeros.
    public func lastWeeks(_ events: [UsageEvent], count: Int, now: Date = Date()) -> [(weekStart: Date, totals: TokenTotals)] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var byWeek: [Date: TokenTotals] = [:]
        for e in events {
            if let ws = calendar.dateInterval(of: .weekOfYear, for: e.timestamp)?.start {
                byWeek[ws, default: TokenTotals()].add(e)
            }
        }
        return (0..<count).reversed().compactMap { back in
            guard let ws = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek) else { return nil }
            return (ws, byWeek[ws] ?? TokenTotals())
        }
    }

    /// Merged token totals for events inside the current 5-hour session window,
    /// i.e. `timestamp >= windowStart`. Used for the "burning X tok/hr" figure.
    public func sinceWindow(_ events: [UsageEvent], windowStart: Date, now: Date = Date()) -> TokenTotals {
        var totals = TokenTotals()
        for e in events where e.timestamp >= windowStart && e.timestamp <= now { totals.add(e) }
        return totals
    }

    /// Decode a `~/.claude/projects/<slug>/…jsonl` path into a display path.
    /// The slug encodes the original project dir with `/` → `-`; we reverse
    /// that best-effort and abbreviate the home dir. Display-only (lossy when a
    /// real directory name contains a dash).
    public static func projectSlug(from sessionPath: String) -> String {
        let parts = sessionPath.split(separator: "/")
        guard let i = parts.firstIndex(of: "projects"), i + 1 < parts.count else {
            return "unknown"
        }
        let slug = String(parts[i + 1])
        // Leading dash = absolute path; turn dashes back into slashes.
        var decoded = slug.hasPrefix("-") ? "/" + slug.dropFirst().replacingOccurrences(of: "-", with: "/")
                                          : slug.replacingOccurrences(of: "-", with: "/")
        if let home = ProcessInfo.processInfo.environment["HOME"], decoded.hasPrefix(home) {
            decoded = "~" + decoded.dropFirst(home.count)
        }
        return decoded
    }
}
