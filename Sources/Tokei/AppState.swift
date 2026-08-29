import AppKit
import Foundation
import Observation
import TrackerCore

/// Owns the non-Sendable core services off the main thread; returns Sendable
/// snapshots for the UI.
actor UsageEngine {
    private let store = UsageStore()
    private let pricingService = PricingService()
    private var catalog: PricingCatalog?

    struct DayPoint: Sendable, Identifiable {
        let day: Date
        let tokens: Int
        var id: Date { day }
    }
    struct WeekPoint: Sendable, Identifiable {
        let weekStart: Date
        let tokens: Int
        let cost: Decimal
        var id: Date { weekStart }
    }

    struct Computed: Sendable {
        var todayRows: [ModelCostRow] = []
        var todayTotal: Decimal = 0
        var todayProjects: [ProjectCostRow] = []
        var monthRows: [ModelCostRow] = []
        var monthTotal: Decimal = 0
        var monthProjects: [ProjectCostRow] = []
        var unpricedModels: Set<String> = []
        var eventCount = 0

        // Analytics
        var daysThisWeek: [DayPoint] = []      // tokens/day, current calendar week (7 points)
        var weeks: [WeekPoint] = []            // last 8 weeks, tokens + cost
        var availableModels: [String] = []     // distinct non-synthetic models seen, for the filter

        // Session window (for burn rate), keyed off local events; the projected
        // exhaustion time comes from the quota bucket, not from these tokens.
        var sessionTokens: Int = 0
        var sessionWindowStart: Date?
    }

    func compute(now: Date = Date()) -> Computed {
        if catalog == nil { catalog = (try? pricingService.load()) ?? PricingCatalog(models: [:]) }
        store.scan()
        let events = store.events
        var calc = CostCalculator(catalog: catalog!)
        let aggregator = UsageAggregator()

        var out = Computed()
        out.eventCount = events.count

        let dayStart = aggregator.calendar.startOfDay(for: now)
        out.todayRows = RowBuilder.rows(byModel: aggregator.today(events, now: now), calculator: &calc)
        out.todayTotal = out.todayRows.reduce(0) { $0 + $1.cost }
        out.todayProjects = RowBuilder.projectRows(
            byProjectModel: aggregator.byProject(events, since: dayStart, now: now), calculator: &calc)

        let monthStart = aggregator.calendar.dateInterval(of: .month, for: now)?.start ?? dayStart
        out.monthRows = RowBuilder.rows(byModel: aggregator.thisMonth(events, now: now),
                                        calculator: &calc, top: 3)
        out.monthTotal = out.monthRows.reduce(0) { $0 + $1.cost }
        out.monthProjects = RowBuilder.projectRows(
            byProjectModel: aggregator.byProject(events, since: monthStart, now: now), calculator: &calc)

        // Analytics: tokens/day this week, and last-8-weeks tokens+cost.
        let weekStart = aggregator.calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let daysSoFar = (aggregator.calendar.dateComponents([.day], from: weekStart, to: dayStart).day ?? 0) + 1
        out.daysThisWeek = aggregator.lastDays(events, count: max(daysSoFar, 1), now: now)
            .map { DayPoint(day: $0.day, tokens: $0.totals.total) }
        for wk in aggregator.lastWeeks(events, count: 8, now: now) {
            let cost = weekCost(events, weekStart: wk.weekStart, calendar: aggregator.calendar, calc: &calc)
            out.weeks.append(WeekPoint(weekStart: wk.weekStart, tokens: wk.totals.total, cost: cost))
        }

        out.availableModels = Set(events.map(\.model))
            .filter { !CostCalculator.isSynthetic($0) }
            .sorted()

        out.unpricedModels = calc.unpricedModels
        return out
    }

    /// Filtered analytics for the pane's pickers: tokens/day and weekly
    /// tokens+cost for one model (nil = all) over the last `days`. Reuses the
    /// already-scanned `store.events` — no transcript re-scan — so it stays
    /// instant even with large history. Weeks span ceil(days/7) to cover the
    /// day range.
    func analytics(model: String?, days: Int) -> (days: [DayPoint], weeks: [WeekPoint]) {
        if catalog == nil { catalog = (try? pricingService.load()) ?? PricingCatalog(models: [:]) }
        let events = model.map { m in store.events.filter { $0.model == m } } ?? store.events
        let aggregator = UsageAggregator()
        var calc = CostCalculator(catalog: catalog!)

        let dayPoints = aggregator.lastDays(events, count: max(days, 1))
            .map { DayPoint(day: $0.day, tokens: $0.totals.total) }
        let weekCount = max((days + 6) / 7, 1)
        let weekPoints = aggregator.lastWeeks(events, count: weekCount).map { wk in
            WeekPoint(weekStart: wk.weekStart, tokens: wk.totals.total,
                      cost: weekCost(events, weekStart: wk.weekStart,
                                     calendar: aggregator.calendar, calc: &calc))
        }
        return (dayPoints, weekPoints)
    }

    /// Cost of one week, summed per model (pricing is model-dependent).
    private func weekCost(_ events: [UsageEvent], weekStart: Date,
                          calendar: Calendar, calc: inout CostCalculator) -> Decimal {
        guard let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { return 0 }
        var byModel: [String: TokenTotals] = [:]
        for e in events where e.timestamp >= weekStart && e.timestamp < weekEnd {
            byModel[e.model, default: TokenTotals()].add(e)
        }
        var cost: Decimal = 0
        for (model, t) in byModel where !CostCalculator.isSynthetic(model) {
            cost += calc.cost(model: model, totals: t)
        }
        return cost
    }

    /// Fill in the session-window token count once the quota window start is
    /// known (from the OAuth bucket). Called after a quota fetch.
    func sessionTokens(windowStart: Date, now: Date = Date()) -> Int {
        store.scan()
        return UsageAggregator().sinceWindow(store.events, windowStart: windowStart, now: now).total
    }

    /// Refresh the LiteLLM catalog when the on-disk cache is stale; failures
    /// keep the current catalog.
    func refreshPricingIfStale() async {
        guard pricingService.cacheIsStale() else { return }
        if let fresh = try? await pricingService.refresh() { catalog = fresh }
    }

    // Token cached in memory so the 5-min poll doesn't re-read the Keychain
    // (each read can show a password prompt until "Always Allow" is granted).
    // A denial latches: background polls stop touching the Keychain; only a
    // user-initiated refresh (popover open / Refresh button) retries.
    private var cachedToken: String?
    private var keychainDenied = false

    func fetchQuota(retryDenied: Bool = false) async -> QuotaState {
        if keychainDenied && !retryDenied { return .accessDenied }
        let token: String
        if let cachedToken {
            token = cachedToken
        } else {
            switch KeychainCredentialReader().readAccessToken() {
            case .notFound: return .noCredentials
            case .denied: keychainDenied = true; return .accessDenied
            case .failure(let status): return .networkError("Keychain error (\(status))")
            case .token(let t): cachedToken = t; keychainDenied = false; token = t
            }
        }
        switch await QuotaClient().fetch(token: token) {
        case .success(let snapshot): return .available(snapshot)
        case .failure(.tokenExpired): cachedToken = nil; return .tokenExpired
        case .failure(let err): return .networkError("\(err)")
        }
    }
}

/// Update lifecycle as the popover sees it.
enum UpdateStatus: Equatable {
    case idle
    case available(AvailableUpdate)
    case installing
    case failed(String)
}

@Observable @MainActor
final class AppState {
    var quota: QuotaState?                  // nil until the first fetch lands
    var lastSnapshot: QuotaSnapshot?        // retained across network errors
    var usage = UsageEngine.Computed()
    var lastRefreshed: Date?
    var updateStatus: UpdateStatus = .idle

    private let engine = UsageEngine()
    private var polling = false
    private var watcher: DirectoryWatcher?
    // Start of the current 5h quota window, learned from the last quota fetch.
    // Persisted here (not in Computed) so file-event refreshes — which rebuild
    // Computed from scratch — can re-fill the session burn figure instead of
    // blanking it. Cleared once the window resets.
    private var sessionWindowStart: Date?
    private var sessionResetsAt: Date?
    private var lastUpdateCheck: Date?

    // Alert latches: fire once per reset boundary. Quota latch clears when the
    // session window resets (applySessionTokens); cost latch clears at midnight
    // (the .NSCalendarDayChanged observer).
    private let notifier = AlertNotifier()
    private var quotaAlertFired = false
    private var costAlertFired = false
    // Previous session utilization, to detect a window roll (utilization drops
    // when a fresh window opens). Re-arming off the *observed* server reading —
    // not the local clock passing the old resetsAt — avoids refiring under clock
    // skew or a server that still reports the expired window.
    private var lastQuotaUtilization: Double?

    /// Version stamped into the bundle by scripts/bundle.sh.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Running from an installed .app (vs `swift run`) — self-update only makes
    /// sense for the former.
    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() {
        Task {
            await engine.refreshPricingIfStale()
            await startPolling()
        }
        // New JSONL writes → usage-only refresh (quota stays on its 5-min cadence).
        watcher = DirectoryWatcher(directory: UsageStore.defaultProjectsDir) {
            Task { @MainActor [weak self] in await self?.refreshUsage() }
        }
        // Midnight rollover: "today" must recompute even with no file activity.
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                self?.costAlertFired = false   // new day → re-arm the cost alert
                await self?.refreshUsage()
            }
        }
    }

    /// Rescan usage (warm scans are ~ms) and re-poll quota. `userInitiated`
    /// lets a popover-open/Refresh retry a previously denied Keychain read.
    func refresh(userInitiated: Bool = false) async {
        await refreshUsage()
        let state = await engine.fetchQuota(retryDenied: userInitiated)
        if case .available(let snapshot) = state {
            lastSnapshot = snapshot
            await fillSessionWindow(snapshot)
        }
        quota = state
        await evaluateAlerts()
    }

    /// Fire quota/cost notifications on threshold crossings, latched so a datum
    /// that stays past the threshold across polls only notifies once. Gated by
    /// the shared enable toggle; thresholds live in UserDefaults. Called at the
    /// end of refresh, when both quota and usage are current.
    private func evaluateAlerts() async {
        guard UserDefaults.standard.object(forKey: "quotaAlertsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "quotaAlertsEnabled") else { return }

        // Quota-remaining alert (default threshold 20%, 0 = off).
        let d = UserDefaults.standard
        let quotaThreshold = d.object(forKey: "quotaAlertRemainingPct") == nil
            ? 20.0 : d.double(forKey: "quotaAlertRemainingPct")
        if case .available(let snapshot) = quota, let session = snapshot.sessionBucket {
            // Window roll: a fresh window opens with lower utilization. Re-arm off
            // this observed drop rather than the local clock, so a skewed clock or
            // a lagging server can't clear the latch while the old window still
            // reads full. (0.05 tolerance ignores normal within-window jitter.)
            if let last = lastQuotaUtilization, session.utilization < last - 0.05 {
                quotaAlertFired = false
            }
            lastQuotaUtilization = session.utilization

            let remainingPct = (1 - session.utilization) * 100
            if AlertLatch.shouldFireQuota(remainingPct: remainingPct, thresholdPct: quotaThreshold,
                                          alreadyFired: quotaAlertFired) {
                quotaAlertFired = true
                await notifier.notify(title: loc("alert.quota.title"),
                                      body: String(localized: "alert.quota.body \(Int(remainingPct.rounded()))",
                                                   bundle: .l10n))
            }
        }

        // Daily-cost alert (default 0 = off).
        let costThreshold = Decimal(d.double(forKey: "dailyCostAlertDollars"))
        if AlertLatch.shouldFireCost(todayDollars: usage.todayTotal, thresholdDollars: costThreshold,
                                     alreadyFired: costAlertFired) {
            costAlertFired = true
            await notifier.notify(title: loc("alert.cost.title"),
                                  body: String(localized: "alert.cost.body \(costString(usage.todayTotal))",
                                               bundle: .l10n))
        }
    }

    /// Once quota is known, record the 5h session window so later local-only
    /// refreshes can keep the burn figure current.
    private func fillSessionWindow(_ snapshot: QuotaSnapshot) async {
        guard let bucket = snapshot.sessionBucket,
              let start = bucket.windowStart(length: 5 * 3600) else { return }
        sessionWindowStart = start
        sessionResetsAt = bucket.resetsAt
        await applySessionTokens()
    }

    /// Recompute the session-window token count from the stored window start,
    /// unless the window has already reset. Cheap; runs after every rescan.
    private func applySessionTokens() async {
        guard let start = sessionWindowStart else { return }
        if let reset = sessionResetsAt, Date() >= reset {
            sessionWindowStart = nil; sessionResetsAt = nil
            usage.sessionWindowStart = nil; usage.sessionTokens = 0
            return
        }
        usage.sessionWindowStart = start
        usage.sessionTokens = await engine.sessionTokens(windowStart: start)
    }

    /// Cheap local-only refresh: no network, safe to run on every file event.
    /// `compute()` returns a fresh Computed (session fields zeroed), so re-fill
    /// them from the persisted window start.
    func refreshUsage() async {
        usage = await engine.compute()
        await applySessionTokens()
        lastRefreshed = Date()
    }

    /// Forward the Analytics pane's filter to the engine. Kept here because the
    /// engine actor is private to AppState.
    func analytics(model: String?, days: Int) async -> (days: [UsageEngine.DayPoint], weeks: [UsageEngine.WeekPoint]) {
        await engine.analytics(model: model, days: days)
    }

    /// Poll GitHub for a newer release, at most every 6 hours. Silent on
    /// failure — a missed check is not worth a UI error; the next one retries.
    func checkForUpdate(force: Bool = false) async {
        guard bundled else { return }
        if case .installing = updateStatus { return }
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastUpdateCheck = Date()

        if case .success(let update) = await UpdateChecker().check(currentVersion: Self.currentVersion) {
            if let update { updateStatus = .available(update) }
        }
    }

    /// Download, verify, then hand off to the detached swap script and quit —
    /// the script relaunches the new build once this process is gone.
    func installUpdate(_ update: AvailableUpdate) async {
        updateStatus = .installing
        let installer = UpdateInstaller()
        do {
            let staged = try await installer.stage(update)
            try installer.installOnExit(staged: staged, installedAt: Bundle.main.bundleURL)
            NSApplication.shared.terminate(nil)
        } catch {
            updateStatus = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateInstaller.InstallError.download(let m): return "Download failed: \(m)"
        case UpdateInstaller.InstallError.unpack(let m): return "Unpack failed: \(m)"
        case UpdateInstaller.InstallError.noBundleInArchive: return "No app found in the download."
        case UpdateInstaller.InstallError.identifierMismatch: return "Downloaded app is not Tokei."
        case UpdateInstaller.InstallError.notInstalled(let p): return "Not installed at \(p)."
        case UpdateInstaller.InstallError.swapFailed(let m): return "Install failed: \(m)"
        default: return error.localizedDescription
        }
    }

    /// Background cadence: every 5 minutes. Opening the popover triggers an
    /// immediate refresh (see UsagePopoverView.onAppear), which stands in for
    /// the planned 60s-while-open interval.
    private func startPolling() async {
        guard !polling else { return }
        polling = true
        while !Task.isCancelled {
            await refresh()
            await checkForUpdate()   // self-throttled to every 6h
            // Read per-iteration so a Settings change takes effect next wake,
            // no loop teardown. Floored at 60s inside currentSeconds.
            let seconds = PollInterval.currentSeconds
            assert(seconds >= 60)
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    /// Label text, per the user's MenuBarMode choice. Each mode keeps the same
    /// fallback chain (primary datum → today's cost → "LLM") so the label is
    /// never blank. Re-read every 2s by the status item's render timer, so a
    /// mode change takes effect without a restart.
    var menuBarText: String {
        switch MenuBarMode.current {
        case .quota:
            if let pct = quotaPercent { return "\(pct)%" }
        case .cost:
            if usage.todayTotal > 0 { return costString(usage.todayTotal) }
        case .burn:
            if let rate = burn?.tokensPerHour { return tokenString(rate) + "/h" }
        }
        if usage.todayTotal > 0 { return costString(usage.todayTotal) }
        return "LLM"
    }

    /// Session quota as a whole-number percent (remaining or used per setting),
    /// or nil when no quota snapshot is available.
    private var quotaPercent: Int? {
        guard case .available(let snapshot) = quota, let session = snapshot.sessionBucket else { return nil }
        let pct = PercentageMode.current.fraction(usedUtilization: session.utilization)
        return Int((pct * 100).rounded())
    }

    var menuBarWarning: Bool {
        if case .available(let snapshot) = quota, let session = snapshot.sessionBucket {
            return session.utilization > 0.9
        }
        return false
    }

    /// Burn rate over the current session window, plus the utilization-based
    /// projected-exhaustion time. Nil when idle or no quota window is known.
    struct BurnInfo { let tokensPerHour: Int; let projectedLimit: Date? }

    var burn: BurnInfo? {
        guard let start = usage.sessionWindowStart, usage.sessionTokens > 0 else { return nil }
        let hours = Date().timeIntervalSince(start) / 3600
        guard hours > 0 else { return nil }
        let rate = Int((Double(usage.sessionTokens) / hours).rounded())
        var projected: Date?
        if case .available(let snapshot) = quota, let bucket = snapshot.sessionBucket {
            projected = bucket.projectedLimit(windowStart: start)
        }
        return BurnInfo(tokensPerHour: rate, projectedLimit: projected)
    }
}

func costString(_ d: Decimal) -> String {
    "$" + String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
}
