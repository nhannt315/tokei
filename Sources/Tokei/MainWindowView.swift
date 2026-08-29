import SwiftUI
import ServiceManagement
import TrackerCore

/// Main window: NavigationSplitView with three flat sections. Overview =
/// "what's happening now", Analytics = "how it's been", Settings = preferences.
struct MainWindowView: View {
    let state: AppState

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", analytics = "Analytics", settings = "Settings"
        var id: String { rawValue }
        /// Localized display name; `rawValue` stays the stable English id/tag.
        var label: String {
            switch self {
            case .overview: return loc("Overview")
            case .analytics: return loc("Analytics")
            case .settings: return loc("Settings")
            }
        }
        var symbol: String {
            switch self {
            case .overview: return "gauge.with.needle"
            case .analytics: return "chart.bar.xaxis"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var selection: Section = .overview

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(190)
            .safeAreaInset(edge: .bottom) {
                Text(verbatim: "Tokei \(AppState.currentVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } detail: {
            switch selection {
            case .overview: OverviewPane(state: state)
            case .analytics: AnalyticsPane(usage: state.usage)
            case .settings: SettingsPane()
            }
        }
        .navigationTitle(selection.label)
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            if selection == .overview {
                Button { Task { await state.refresh(userInitiated: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(loc("Refresh"))
            }
        }
        .task { await state.refresh(userInitiated: true) }
    }
}

// MARK: - Overview

private struct OverviewPane: View {
    let state: AppState
    /// Which timeframe the breakdown tables show.
    @State private var scope: Scope = .today
    enum Scope: String, CaseIterable {
        case today = "Today", month = "This Month"
        var label: String { self == .today ? loc("Today") : loc("This Month") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SessionCard(state: state)

                HStack {
                    Text("Breakdown", bundle: .l10n).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                }

                HStack(alignment: .top, spacing: 16) {
                    ModelTable(rows: rows, total: total)
                    ProjectTable(rows: projects, total: total)
                }
            }
            .padding(20)
        }
    }

    private var rows: [ModelCostRow] { scope == .today ? state.usage.todayRows : state.usage.monthRows }
    private var projects: [ProjectCostRow] { scope == .today ? state.usage.todayProjects : state.usage.monthProjects }
    private var total: Decimal { scope == .today ? state.usage.todayTotal : state.usage.monthTotal }
}

private struct SessionCard: View {
    let state: AppState

    var body: some View {
        let bucket: QuotaBucket? = {
            if case .available(let s) = state.quota { return s.sessionBucket }
            return state.lastSnapshot?.sessionBucket
        }()
        GroupBox {
            if let bucket {
                let status = QuotaStatus(utilization: bucket.utilization)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CURRENT SESSION", bundle: .l10n)
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        if let reset = bucket.resetsAt {
                            (Text("Resets \(reset.formatted(date: .omitted, time: .shortened)) · ", bundle: .l10n)
                             + Text(reset, style: .relative))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: bucket.utilization).tint(status.color)
                    HStack(spacing: 0) {
                        let usedPct = Int((bucket.utilization * 100).rounded())
                        stat("Consumed", tokenString(state.usage.sessionTokens) + " tok") {
                            Text(verbatim: String(format: loc("pct.ofQuota"), usedPct))
                        }
                        if let burn = state.burn {
                            stat("Burn rate", tokenString(burn.tokensPerHour) + " tok/hr") {
                                if let limit = burn.projectedLimit {
                                    Text("limit ≈ \(limit.formatted(date: .omitted, time: .shortened))", bundle: .l10n)
                                } else {
                                    Text(verbatim: "—")
                                }
                            }
                        } else {
                            stat("Burn rate", "—") { Text("idle", bundle: .l10n) }
                        }
                        stat("Remaining", "\(Int(((1 - bucket.utilization) * 100).rounded()))%") {
                            Text(verbatim: "")
                        }
                    }
                }
            } else {
                Text("Quota unavailable", bundle: .l10n).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// `label` localizes; `value` is verbatim (tokens/percent + technical unit);
    /// `sub` is a caller-built (often localized) caption view.
    private func stat<Sub: View>(_ label: LocalizedStringKey, _ value: String,
                                 @ViewBuilder sub: () -> Sub) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label, bundle: .l10n).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            sub().font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelTable: View {
    let rows: [ModelCostRow]
    let total: Decimal

    var body: some View {
        BreakdownTable(header: "Model", total: total, rows: rows.map {
            .init(name: RowBuilder.displayName($0.model), tokens: $0.totals.total, cost: $0.cost)
        })
    }
}

private struct ProjectTable: View {
    let rows: [ProjectCostRow]
    let total: Decimal

    var body: some View {
        BreakdownTable(header: "Project", total: total, rows: rows.map {
            .init(name: $0.project, tokens: $0.totals.total, cost: $0.cost)
        })
    }
}

/// Shared 3-column breakdown table with a Total footer.
private struct BreakdownTable: View {
    struct Row: Identifiable { let name: String; let tokens: Int; let cost: Decimal; var id: String { name } }
    /// Localized column header ("Model" / "Project").
    let header: LocalizedStringKey
    let total: Decimal
    let rows: [Row]

    var body: some View {
        VStack(spacing: 0) {
            // Header cells localize; the name column shows the column title.
            gridRow(name: Text(header, bundle: .l10n),
                    tokens: Text("Tokens", bundle: .l10n),
                    cost: Text("Cost", bundle: .l10n),
                    weight: .semibold, style: AnyShapeStyle(.secondary))
            Divider()
            if rows.isEmpty {
                Text("No usage", bundle: .l10n).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    // Data rows are verbatim: model/project name, tokens, cost.
                    gridRow(name: Text(verbatim: r.name),
                            tokens: Text(verbatim: tokenString(r.tokens)),
                            cost: Text(verbatim: costString(r.cost)),
                            alt: i.isMultiple(of: 2) == false)
                }
                Divider()
                gridRow(name: Text("Total", bundle: .l10n),
                        tokens: Text(verbatim: ""),
                        cost: Text(verbatim: costString(total)),
                        weight: .semibold)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func gridRow(name: Text, tokens: Text, cost: Text,
                         weight: Font.Weight = .regular,
                         style: AnyShapeStyle = AnyShapeStyle(.primary),
                         alt: Bool = false) -> some View {
        HStack(spacing: 8) {
            name.lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            tokens.frame(width: 52, alignment: .trailing).monospacedDigit()
            cost.frame(width: 52, alignment: .trailing).monospacedDigit()
        }
        .font(.caption)
        .fontWeight(weight)
        .foregroundStyle(style)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(alt ? Color.primary.opacity(0.03) : .clear)
    }
}

// MARK: - Settings (moved out of the popover)

struct SettingsPane: View {
    @AppStorage(PercentageMode.defaultsKey) private var mode = PercentageMode.remaining.rawValue
    @AppStorage(MenuBarMode.defaultsKey) private var menuBarMode = MenuBarMode.quota.rawValue
    @AppStorage(PollInterval.defaultsKey) private var pollSeconds = PollInterval.fiveMin.rawValue
    @AppStorage("quotaAlertsEnabled") private var alertsEnabled = true
    @AppStorage(AppearanceMode.defaultsKey) private var appearance = AppearanceMode.system.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var language = LanguageChoice.current
    @State private var languageChanged = false

    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var currentMode: PercentageMode { PercentageMode(rawValue: mode) ?? .remaining }

    var body: some View {
        Form {
            if bundled {
                Section {
                    Toggle(isOn: $launchAtLogin) { Text("Launch at login", bundle: .l10n) }
                        .onChange(of: launchAtLogin) { _, enabled in setLaunch(enabled) }
                    if let loginError {
                        // System error text — not localized by us.
                        Text(loginError).font(.caption).foregroundStyle(.orange)
                    }
                    languageRow
                } header: { Text("General", bundle: .l10n) }
            }
            Section {
                Picker(selection: $menuBarMode) {
                    ForEach(MenuBarMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                } label: { Text("Menu bar shows", bundle: .l10n) }
                .pickerStyle(.segmented)
                Picker(selection: $mode) {
                    ForEach(PercentageMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                } label: { Text("Show quota as", bundle: .l10n) }
                .pickerStyle(.segmented)
                // Built via loc() (not a Text LocalizedStringKey) so the literal
                // "%" in the example isn't parsed as a format specifier.
                Text(verbatim: currentMode == .remaining
                     ? loc("menuBarHint.remaining") : loc("menuBarHint.used"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Menu Bar", bundle: .l10n) }
            Section {
                Picker(selection: $pollSeconds) {
                    ForEach(PollInterval.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                } label: { Text("Quota refresh", bundle: .l10n) }
                .pickerStyle(.segmented)
                Text("Usage and cost still update instantly; this only paces the network quota check.", bundle: .l10n)
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Refresh", bundle: .l10n) }
            Section {
                Picker(selection: $appearance) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                } label: { Text("Appearance", bundle: .l10n) }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, _ in
                    NotificationCenter.default.post(name: AppearanceMode.didChange, object: nil)
                }
            } header: { Text("Appearance", bundle: .l10n) }
            Section {
                Toggle(isOn: $alertsEnabled) { Text("Quota alerts", bundle: .l10n) }
                Text(verbatim: loc("quotaAlerts.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Notifications", bundle: .l10n) }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
    }

    /// Language picker + relaunch note. Language is read once at process start,
    /// so switching requires a relaunch to take effect.
    @ViewBuilder private var languageRow: some View {
        Picker(selection: $language) {
            ForEach(LanguageChoice.allCases, id: \.self) { Text($0.label).tag($0) }
        } label: { Text("Language", bundle: .l10n) }
        .onChange(of: language) { _, choice in
            choice.apply()
            languageChanged = true
        }
        if languageChanged {
            HStack {
                Text("Takes effect after relaunch.", bundle: .l10n)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if bundled {
                    Button { relaunch() } label: { Text("Relaunch", bundle: .l10n) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func setLaunch(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = error.localizedDescription
        }
    }

    /// Quit and reopen so the process re-reads AppleLanguages. Modeled on
    /// UpdateInstaller's detached-swap script: a child shell waits for this
    /// process to exit, then `open -n`s the bundle.
    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open -n '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// In-app language override. `.system` clears AppleLanguages (follow OS);
/// otherwise pin the chosen language, read at next launch.
enum LanguageChoice: String, CaseIterable {
    case system, en, ja

    var label: String {
        switch self {
        case .system: return loc("System")
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    func apply() {
        let key = "AppleLanguages"
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: key)
        case .en, .ja: UserDefaults.standard.set([rawValue], forKey: key)
        }
    }

    /// Current choice, read from the app's OWN defaults domain — not the merged
    /// UserDefaults view, which always carries the OS's AppleLanguages and would
    /// make a mono-language Mac look like it has an override.
    static var current: LanguageChoice {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let langs = domain?["AppleLanguages"] as? [String], langs.count == 1,
              let choice = LanguageChoice(rawValue: String(langs[0].prefix(2)))
        else { return .system }
        return choice
    }
}
