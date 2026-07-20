import Foundation
import Observation
import TrackerCore

/// Owns the non-Sendable core services off the main thread; returns Sendable
/// snapshots for the UI.
actor UsageEngine {
    private let store = UsageStore()
    private let pricingService = PricingService()
    private var catalog: PricingCatalog?

    struct Computed: Sendable {
        var todayRows: [ModelCostRow] = []
        var todayTotal: Decimal = 0
        var monthRows: [ModelCostRow] = []
        var monthTotal: Decimal = 0
        var unpricedModels: Set<String> = []
        var eventCount = 0
    }

    func compute(now: Date = Date()) -> Computed {
        if catalog == nil { catalog = (try? pricingService.load()) ?? PricingCatalog(models: [:]) }
        store.scan()
        let events = store.events
        var calc = CostCalculator(catalog: catalog!)
        let aggregator = UsageAggregator()

        var out = Computed()
        out.eventCount = events.count
        out.todayRows = RowBuilder.rows(byModel: aggregator.today(events, now: now), calculator: &calc)
        out.todayTotal = out.todayRows.reduce(0) { $0 + $1.cost }
        out.monthRows = RowBuilder.rows(byModel: aggregator.thisMonth(events, now: now),
                                        calculator: &calc, top: 3)
        out.monthTotal = out.monthRows.reduce(0) { $0 + $1.cost }
        out.unpricedModels = calc.unpricedModels
        return out
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

@Observable @MainActor
final class AppState {
    var quota: QuotaState?                  // nil until the first fetch lands
    var lastSnapshot: QuotaSnapshot?        // retained across network errors
    var usage = UsageEngine.Computed()
    var lastRefreshed: Date?

    private let engine = UsageEngine()
    private var polling = false
    private var watcher: DirectoryWatcher?

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
            Task { @MainActor [weak self] in await self?.refreshUsage() }
        }
    }

    /// Rescan usage (warm scans are ~ms) and re-poll quota. `userInitiated`
    /// lets a popover-open/Refresh retry a previously denied Keychain read.
    func refresh(userInitiated: Bool = false) async {
        await refreshUsage()
        let state = await engine.fetchQuota(retryDenied: userInitiated)
        if case .available(let snapshot) = state { lastSnapshot = snapshot }
        quota = state
    }

    /// Cheap local-only refresh: no network, safe to run on every file event.
    func refreshUsage() async {
        usage = await engine.compute()
        lastRefreshed = Date()
    }

    /// Background cadence: every 5 minutes. Opening the popover triggers an
    /// immediate refresh (see UsagePopoverView.onAppear), which stands in for
    /// the planned 60s-while-open interval.
    private func startPolling() async {
        guard !polling else { return }
        polling = true
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(300))
        }
    }

    /// Label text: remaining session quota, else today's cost, else placeholder.
    var menuBarText: String {
        if case .available(let snapshot) = quota,
           let session = snapshot.buckets.first {
            return "\(Int(((1 - session.utilization) * 100).rounded()))%"
        }
        if usage.todayTotal > 0 { return costString(usage.todayTotal) }
        return "LLM"
    }

    var menuBarWarning: Bool {
        if case .available(let snapshot) = quota, let session = snapshot.buckets.first {
            return session.utilization > 0.9
        }
        return false
    }
}

func costString(_ d: Decimal) -> String {
    "$" + String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
}
