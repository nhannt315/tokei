import SwiftUI
import ServiceManagement
import TrackerCore

struct UsagePopoverView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuotaSection(state: state)
            Divider()
            TodaySection(usage: state.usage)
            Divider()
            MonthSection(usage: state.usage)
            Divider()
            FooterSection(state: state)
        }
        .padding(12)
        .frame(width: 320)
        .task { await state.refresh(userInitiated: true) }
    }
}

// MARK: - Quota

private struct QuotaSection: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quota").font(.headline)
            switch state.quota {
            case nil:
                Text("Loading…").foregroundStyle(.secondary)
            case .available(let snapshot):
                bars(snapshot)
            case .noCredentials:
                Text("No credentials found. Sign in to Claude Code.")
                    .foregroundStyle(.secondary)
            case .tokenExpired:
                Text("Session expired. Open Claude Code to refresh it.")
                    .foregroundStyle(.secondary)
            case .accessDenied:
                Text("Keychain access denied. Approve the prompt to show quota.")
                    .foregroundStyle(.secondary)
            case .networkError(let message):
                if let stale = state.lastSnapshot {
                    bars(stale)
                    Text("Offline — data from \(stale.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Can't reach quota endpoint: \(message)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bars(_ snapshot: QuotaSnapshot) -> some View {
        ForEach(snapshot.buckets, id: \.key) { bucket in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Self.title(bucket.key))
                    Spacer()
                    Text("\(Int((bucket.utilization * 100).rounded()))% used")
                        .foregroundStyle(bucket.utilization > 0.9 ? .red : .secondary)
                }
                .font(.callout)
                ProgressView(value: bucket.utilization)
                if let reset = bucket.resetsAt {
                    Text("resets in ") .font(.caption).foregroundStyle(.secondary)
                    + Text(reset, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func title(_ key: String) -> String {
        switch key {
        case "session", "five_hour": return "Session (5h)"
        case "weekly_all", "seven_day": return "Weekly (all models)"
        default:
            if let name = key.split(separator: ":").last, key.contains(":") {
                return "Weekly · \(name)"
            }
            return key
        }
    }
}

// MARK: - Today / Month

private struct TodaySection: View {
    let usage: UsageEngine.Computed

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                Text(costString(usage.todayTotal)).font(.headline)
            }
            if usage.eventCount == 0 {
                Text("No Claude Code data found").foregroundStyle(.secondary)
            } else if usage.todayRows.isEmpty {
                Text("No usage today").foregroundStyle(.secondary)
            } else {
                ForEach(usage.todayRows) { row in
                    HStack {
                        Text(RowBuilder.displayName(row.model))
                        Spacer()
                        Text("\(row.totals.total.formatted()) tok")
                            .foregroundStyle(.secondary).font(.caption)
                        Text(costString(row.cost)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            if !usage.unpricedModels.isEmpty {
                Label("No pricing for: \(usage.unpricedModels.sorted().joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct MonthSection: View {
    let usage: UsageEngine.Computed

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("This month").font(.headline)
                Spacer()
                Text(costString(usage.monthTotal)).font(.headline)
            }
            ForEach(usage.monthRows) { row in
                HStack {
                    Text(RowBuilder.displayName(row.model))
                    Spacer()
                    Text(costString(row.cost)).monospacedDigit()
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Footer

private struct FooterSection: View {
    let state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    // SMAppService only works from a real installed .app bundle.
    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bundled {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .font(.callout)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                if let stamp = state.lastRefreshed {
                    Text("Updated \(stamp.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await state.refresh(userInitiated: true) } }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .controlSize(.small)
    }
}
