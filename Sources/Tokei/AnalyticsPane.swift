import SwiftUI
import Charts
import TrackerCore

/// Analytics: tokens/day and weekly cost, filterable by model and lookback
/// window. Charts draw from a filtered recompute (no transcript re-scan);
/// ContentUnavailableView until first usage, and an empty state when a filter
/// yields nothing.
struct AnalyticsPane: View {
    let state: AppState

    // nil = all models. Lookback in days; default 56 = the previous 8-week view.
    @State private var selectedModel: String?
    @State private var lookbackDays = 56
    // nil until the first fetch lands, so an unloaded pane isn't mistaken for a
    // genuinely-empty range (which would flash the empty state on first appear).
    @State private var points: (days: [UsageEngine.DayPoint], weeks: [UsageEngine.WeekPoint])?
    @State private var fetchTask: Task<Void, Never>?

    private static let lookbacks = [7, 30, 56, 90]

    var body: some View {
        if state.usage.eventCount == 0 {
            ContentUnavailableView {
                Label { Text("No usage yet", bundle: .l10n) } icon: { Image(systemName: "chart.bar.xaxis") }
            } description: {
                Text("Charts appear after your first Claude Code session is recorded.", bundle: .l10n)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    filters
                    if let points {
                        if points.days.allSatisfy({ $0.tokens == 0 }) && points.weeks.allSatisfy({ $0.tokens == 0 }) {
                            ContentUnavailableView {
                                Label { Text("No usage in this range", bundle: .l10n) } icon: { Image(systemName: "line.diagonal") }
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            TokensPerDayChart(days: points.days)
                            HStack(alignment: .top, spacing: 16) {
                                WeeklyCostChart(weeks: points.weeks)
                                WeeklyRollupTable(weeks: points.weeks)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .task { reload() }
            .onChange(of: selectedModel) { _, _ in reload() }
            .onChange(of: lookbackDays) { _, _ in reload() }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker(selection: $selectedModel) {
                Text("All models", bundle: .l10n).tag(String?.none)
                ForEach(state.usage.availableModels, id: \.self) {
                    Text(verbatim: RowBuilder.displayName($0)).tag(String?.some($0))
                }
            } label: { Text("Model", bundle: .l10n) }
            Picker(selection: $lookbackDays) {
                ForEach(Self.lookbacks, id: \.self) {
                    Text(verbatim: String(localized: "\($0) days", bundle: .l10n)).tag($0)
                }
            } label: { Text("Range", bundle: .l10n) }
        }
        .frame(maxWidth: 460)
    }

    /// Cancel any in-flight fetch and load the current filter — a single Task
    /// handle so rapid picker changes can't race stale results onto the charts.
    private func reload() {
        fetchTask?.cancel()
        let model = selectedModel, days = lookbackDays
        fetchTask = Task {
            let result = await state.analytics(model: model, days: days)
            if !Task.isCancelled { points = result }
        }
    }
}

private struct TokensPerDayChart: View {
    let days: [UsageEngine.DayPoint]
    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("TOKENS PER DAY — THIS WEEK", bundle: .l10n)
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Chart(days) { d in
                    BarMark(x: .value("Day", d.day, unit: .day),
                            y: .value("Tokens", d.tokens))
                        .foregroundStyle(d.day == todayStart ? Color.accentColor : Color.secondary)
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                } }
                .chartYAxis { AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    if let tokens = value.as(Int.self) {
                        AxisValueLabel { Text(tokenString(tokens)) }
                    }
                } }
                .frame(height: 120)
            }
        }
    }
}

private struct WeeklyCostChart: View {
    let weeks: [UsageEngine.WeekPoint]
    private var thisWeekStart: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("WEEKLY COST — LAST 8 WEEKS", bundle: .l10n)
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Chart(weeks) { w in
                    BarMark(x: .value("Week", w.weekStart, unit: .weekOfYear),
                            y: .value("Cost", NSDecimalNumber(decimal: w.cost).doubleValue))
                        .foregroundStyle(w.weekStart == thisWeekStart ? Color.accentColor : Color.secondary)
                        .cornerRadius(3)
                }
                .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0)), position: .leading) }
                .frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WeeklyRollupTable: View {
    let weeks: [UsageEngine.WeekPoint]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ForEach(Array(weeks.reversed().enumerated()), id: \.element.id) { i, w in
                row(label: Self.range(w.weekStart), tokens: tokenString(w.tokens),
                    cost: costString(w.cost), alt: i.isMultiple(of: 2) == false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Week", bundle: .l10n).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Text("Tokens", bundle: .l10n).frame(width: 52, alignment: .trailing)
            Text("Cost", bundle: .l10n).frame(width: 52, alignment: .trailing)
        }
        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func row(label: String, tokens: String, cost: String, alt: Bool) -> some View {
        HStack(spacing: 8) {
            // label/tokens/cost are locale-formatted values → verbatim.
            Text(verbatim: label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Text(verbatim: tokens).frame(width: 52, alignment: .trailing).monospacedDigit()
            Text(verbatim: cost).frame(width: 52, alignment: .trailing).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(alt ? Color.primary.opacity(0.03) : .clear)
    }

    /// Locale-aware week range. en: "Aug 10 – 16"; ja: "8/10～8/16". The
    /// interval formatter picks the region's separator and field order.
    static func range(_ start: Date) -> String {
        // Half-open [start, start+6d): the interval formatter renders the last
        // included day, reading Mon–Sun in en and 8/10～8/16 in ja.
        let lastDay = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        return (start..<lastDay).formatted(.interval.month(.abbreviated).day())
    }
}
