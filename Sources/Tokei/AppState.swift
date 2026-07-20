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
    private var lastUpdateCheck: Date?

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
