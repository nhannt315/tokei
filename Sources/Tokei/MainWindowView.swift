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
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(190)
            .safeAreaInset(edge: .bottom) {
                Text("Tokei \(AppState.currentVersion)")
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
        .navigationTitle(selection.rawValue)
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            if selection == .overview {
                Button { Task { await state.refresh(userInitiated: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
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
    enum Scope: String, CaseIterable { case today = "Today", month = "This Month" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SessionCard(state: state)

                HStack {
                    Text("Breakdown").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("", selection: $scope) {
                        ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
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
                        Text("CURRENT SESSION").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        if let reset = bucket.resetsAt {
                            (Text("Resets \(reset.formatted(date: .omitted, time: .shortened)) · ")
                             + Text(reset, style: .relative))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: bucket.utilization).tint(status.color)
                    HStack(spacing: 0) {
                        stat("Consumed", tokenString(state.usage.sessionTokens) + " tok",
                             sub: "\(Int((bucket.utilization * 100).rounded()))% of quota")
                        if let burn = state.burn {
                            stat("Burn rate", tokenString(burn.tokensPerHour) + " tok/hr",
                                 sub: burn.projectedLimit.map { "limit ≈ \($0.formatted(date: .omitted, time: .shortened))" } ?? "—")
                        } else {
                            stat("Burn rate", "—", sub: "idle")
                        }
                        stat("Remaining", "\(Int(((1 - bucket.utilization) * 100).rounded()))%",
                             sub: "")
                    }
                }
            } else {
                Text("Quota unavailable").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stat(_ label: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Text(sub).font(.caption).foregroundStyle(.secondary)
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
    let header: String
    let total: Decimal
    let rows: [Row]

    var body: some View {
        VStack(spacing: 0) {
            row(header, "Tokens", "Cost", isHeader: true)
            Divider()
            if rows.isEmpty {
                Text("No usage").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    row(r.name, tokenString(r.tokens), costString(r.cost), alt: i.isMultiple(of: 2) == false)
                }
                Divider()
                row("Total", "", costString(total), isFooter: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func row(_ name: String, _ tokens: String, _ cost: String,
                     isHeader: Bool = false, isFooter: Bool = false, alt: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            Text(tokens).frame(width: 52, alignment: .trailing).monospacedDigit()
            Text(cost).frame(width: 52, alignment: .trailing).monospacedDigit()
        }
        .font(.caption)
        .fontWeight(isHeader || isFooter ? .semibold : .regular)
        .foregroundStyle(isHeader ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(alt ? Color.primary.opacity(0.03) : .clear)
    }
}

// MARK: - Settings (moved out of the popover)

struct SettingsPane: View {
    @AppStorage(PercentageMode.defaultsKey) private var mode = PercentageMode.remaining.rawValue
    @AppStorage("quotaAlertsEnabled") private var alertsEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var currentMode: PercentageMode { PercentageMode(rawValue: mode) ?? .remaining }

    var body: some View {
        Form {
            if bundled {
                Section("General") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in setLaunch(enabled) }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Section("Menu Bar") {
                Picker("Show quota as", selection: $mode) {
                    ForEach(PercentageMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text("Menu bar and popover will show e.g. \"82% \(currentMode == .remaining ? "remaining" : "used")\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Quota alerts", isOn: $alertsEnabled)
                Text("Notifies when the 5-hour session reaches 70% and 90% used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
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
}
