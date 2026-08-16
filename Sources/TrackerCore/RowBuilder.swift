import Foundation

/// One display row: a model with its tokens and cost.
public struct ModelCostRow: Sendable, Identifiable {
    public let model: String
    public let totals: TokenTotals
    public let cost: Decimal

    public var id: String { model }

    public init(model: String, totals: TokenTotals, cost: Decimal) {
        self.model = model
        self.totals = totals
        self.cost = cost
    }
}

/// One display row: a project (folder path) with its tokens and cost.
public struct ProjectCostRow: Sendable, Identifiable {
    public let project: String
    public let totals: TokenTotals
    public let cost: Decimal

    public var id: String { project }

    public init(project: String, totals: TokenTotals, cost: Decimal) {
        self.project = project
        self.totals = totals
        self.cost = cost
    }
}

/// Pure row assembly for the UI: cost-sorted, synthetic/zero rows dropped,
/// everything beyond the top N collapsed into an "other" row.
public enum RowBuilder {
    /// Cost-sorted project rows. Cost is summed per model within each project
    /// (pricing is model-dependent), then collapsed beyond `top`.
    public static func projectRows(byProjectModel: [String: [String: TokenTotals]],
                                   calculator: inout CostCalculator,
                                   top: Int = 5) -> [ProjectCostRow] {
        var rows: [ProjectCostRow] = []
        for (project, byModel) in byProjectModel {
            var totals = TokenTotals()
            var cost: Decimal = 0
            for (model, t) in byModel where !CostCalculator.isSynthetic(model) {
                totals.merge(t)
                cost += calculator.cost(model: model, totals: t)
            }
            guard totals.total > 0 else { continue }
            rows.append(ProjectCostRow(project: project, totals: totals, cost: cost))
        }
        rows.sort { $0.cost != $1.cost ? $0.cost > $1.cost : $0.project < $1.project }
        guard rows.count > top else { return rows }
        let extra = rows[top...]
        var totals = TokenTotals()
        var cost: Decimal = 0
        for r in extra { totals.merge(r.totals); cost += r.cost }
        return Array(rows[..<top])
            + [ProjectCostRow(project: "other (\(extra.count))", totals: totals, cost: cost)]
    }

    public static func rows(byModel: [String: TokenTotals],
                            calculator: inout CostCalculator,
                            top: Int = 5) -> [ModelCostRow] {
        var rows: [ModelCostRow] = []
        for (model, totals) in byModel {
            guard !CostCalculator.isSynthetic(model), totals.total > 0 else { continue }
            rows.append(ModelCostRow(model: model, totals: totals,
                                     cost: calculator.cost(model: model, totals: totals)))
        }
        rows.sort { $0.cost != $1.cost ? $0.cost > $1.cost : $0.model < $1.model }
        guard rows.count > top else { return rows }
        let extra = rows[top...]
        var totals = TokenTotals()
        var cost: Decimal = 0
        for r in extra {
            totals.merge(r.totals)
            cost += r.cost
        }
        return Array(rows[..<top])
            + [ModelCostRow(model: "other (\(extra.count) models)", totals: totals, cost: cost)]
    }

    /// "claude-opus-4-8" → "opus-4-8"; "claude-sonnet-5-20260203" → "sonnet-5".
    /// Display-only; never used for pricing lookups.
    public static func displayName(_ model: String) -> String {
        var name = model
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        // Trailing -YYYYMMDD date suffix
        if name.count > 9, name[name.index(name.endIndex, offsetBy: -9)] == "-",
           name.suffix(8).allSatisfy(\.isNumber) {
            name.removeLast(9)
        }
        return name
    }
}
