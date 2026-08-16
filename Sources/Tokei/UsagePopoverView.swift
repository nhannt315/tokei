import SwiftUI
import TrackerCore

/// Menu-bar popover: a strict glance. Two quota bars, cost pair, burn line,
/// one button into the main window. Settings and Quit live elsewhere (main
/// window and the status-item right-click menu).
struct UsagePopoverView: View {
    let state: AppState
    let onOpenMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            QuotaBars(state: state)
            Divider()
            costPair
            if let burn = state.burn, !isOffline {
                BurnLine(burn: burn)
            }
            if !state.usage.unpricedModels.isEmpty {
                Label {
                    Text("No pricing for: \(state.usage.unpricedModels.sorted().joined(separator: ", "))",
                         bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption).foregroundStyle(.orange)
            }
            UpdateSection(state: state)
            Divider()
            Button { onOpenMainWindow() } label: { Text("Open Tokei…", bundle: .module) }
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(width: 340)
        .task { await state.refresh(userInitiated: true) }
    }

    private var isOffline: Bool {
        if case .networkError = state.quota, state.lastSnapshot != nil { return true }
        return false
    }

    private var header: some View {
        HStack {
            Text(verbatim: "Tokei").font(.system(size: 13, weight: .bold))
            Spacer()
            if let stamp = state.lastRefreshed {
                Text("Updated \(stamp.formatted(date: .omitted, time: .shortened))", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await state.refresh(userInitiated: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(loc("Refresh"))
        }
    }

    private var costPair: some View {
        HStack(spacing: 0) {
            costColumn("Today", state.usage.todayTotal)
            costColumn("This month", state.usage.monthTotal)
        }
    }

    private func costColumn(_ label: LocalizedStringKey, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label, bundle: .module).font(.caption).foregroundStyle(.secondary)
            Text(costString(value)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quota bars (with error / offline / loading states)

private struct QuotaBars: View {
    let state: AppState
    @AppStorage(PercentageMode.defaultsKey) private var modeRaw = PercentageMode.remaining.rawValue
    private var mode: PercentageMode { PercentageMode(rawValue: modeRaw) ?? .remaining }

    var body: some View {
        switch state.quota {
        case nil:
            loading
        case .available(let snapshot):
            bars(snapshot, stale: false)
        case .noCredentials:
            errorCard("No credentials", detail: "Sign in to Claude Code, then retry.")
        case .tokenExpired:
            errorCard("Session expired", detail: "Quota can't be read. Re-authenticate in Claude Code, then retry.")
        case .accessDenied:
            errorCard("Keychain access denied", detail: "Approve the Keychain prompt to show quota.")
        case .networkError(let message):
            if let stale = state.lastSnapshot {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Offline — last snapshot at \(stale.fetchedAt.formatted(date: .omitted, time: .shortened))",
                             bundle: .module)
                    } icon: {
                        Image(systemName: "wifi.slash")
                    }
                    .font(.caption).foregroundStyle(.orange)
                    bars(stale, stale: true).opacity(0.55)
                }
            } else {
                // `message` is a raw diagnostic (e.g. "http(429)") — not localized.
                errorCard("Offline", verbatimDetail: message)
            }
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.15))
                        .frame(width: 120, height: 11)
                    RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.15)).frame(height: 6)
                }
            }
        }
    }

    private func errorCard(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        errorCard(title) { Text(detail, bundle: .module) }
    }

    /// Variant for a raw, non-localizable detail string (e.g. an HTTP error).
    private func errorCard(_ title: LocalizedStringKey, verbatimDetail: String) -> some View {
        errorCard(title) { Text(verbatimDetail) }
    }

    private func errorCard<Detail: View>(_ title: LocalizedStringKey,
                                         @ViewBuilder detail: () -> Detail) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.title3)
            Text(title, bundle: .module).font(.system(size: 13, weight: .semibold))
            detail().font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { Task { await state.refresh(userInitiated: true) } } label: {
                Text("Retry", bundle: .module)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder
    private func bars(_ snapshot: QuotaSnapshot, stale: Bool) -> some View {
        let ordered = orderedBuckets(snapshot)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ordered, id: \.key) { bucket in
                bar(bucket)
            }
        }
    }

    /// Session first, then weekly, then any model-specific caps in original order.
    private func orderedBuckets(_ snapshot: QuotaSnapshot) -> [QuotaBucket] {
        var head: [QuotaBucket] = []
        if let s = snapshot.sessionBucket { head.append(s) }
        if let w = snapshot.weeklyBucket { head.append(w) }
        let headKeys = Set(head.map(\.key))
        return head + snapshot.buckets.filter { !headKeys.contains($0.key) }
    }

    private func bar(_ bucket: QuotaBucket) -> some View {
        let status = QuotaStatus(utilization: bucket.utilization)
        let shown = mode.fraction(usedUtilization: bucket.utilization)
        let pct = Int((shown * 100).rounded())
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(bucketShortTitle(bucket.key)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: String(format: loc(mode == .remaining ? "pct.remaining" : "pct.used"), pct))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(status == .healthy ? .primary : status.color)
            }
            ProgressView(value: shown)
                .tint(status.color)
            if let reset = bucket.resetsAt {
                Text("Resets \(reset.formatted(date: .omitted, time: .shortened)) · ", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
                + Text(reset, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Burn line

private struct BurnLine: View {
    let burn: AppState.BurnInfo

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.needle").font(.caption)
            Text("Burning \(tokenString(burn.tokensPerHour)) tok/hr", bundle: .module)
            if let limit = burn.projectedLimit {
                Text("· at this pace, limit ≈ \(limit.formatted(date: .omitted, time: .shortened))", bundle: .module)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Update (kept from the prior popover — not in the design spec but real)

/// Renders nothing in the common case. Speaks up only when there is an update
/// to install or a failure to report.
private struct UpdateSection: View {
    let state: AppState

    var body: some View {
        switch state.updateStatus {
        case .idle:
            EmptyView()
        case .available(let update):
            HStack {
                Label {
                    Text("Version \(update.version) available", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .font(.callout)
                Spacer()
                Button { Task { await state.installUpdate(update) } } label: {
                    Text("Update", bundle: .module)
                }
            }
            .controlSize(.small)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading update…", bundle: .module).font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                // `message` is a raw diagnostic from AppState.describe — not localized.
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Link(destination: URL(string: "https://github.com/nhannt315/tokei/releases/latest")!) {
                    Text("Download manually", bundle: .module)
                }
                .font(.caption)
            }
        }
    }
}
