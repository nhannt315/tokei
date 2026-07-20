import Foundation

/// Turns token totals into USD using a `PricingCatalog`. Decimal arithmetic.
///
/// Known limitation (validated decision): server-tool usage (web search
/// queries) is deliberately not costed — matches ccusage behavior.
public struct CostCalculator {
    public let catalog: PricingCatalog
    /// Models seen but absent from the catalog — surfaced so the UI can warn
    /// instead of silently under-reporting.
    public private(set) var unpricedModels: Set<String> = []

    public init(catalog: PricingCatalog) {
        self.catalog = catalog
    }

    /// Synthetic/error pseudo-models that carry no billable usage.
    public static func isSynthetic(_ model: String) -> Bool {
        model.hasPrefix("<")
    }

    public mutating func cost(model: String, totals: TokenTotals) -> Decimal {
        guard !Self.isSynthetic(model) else { return 0 }
        guard let p = catalog.pricing(for: model) else {
            unpricedModels.insert(model)
            return 0
        }
        return Decimal(totals.input) * p.input
            + Decimal(totals.output) * p.output
            + Decimal(totals.cacheRead) * p.cacheRead
            + Decimal(totals.cacheCreate5m) * p.cacheWrite5m
            + Decimal(totals.cacheCreate1h) * p.cacheWrite1h
    }

    /// model → cost for a per-model totals map; returns the map plus grand total.
    public mutating func costs(byModel: [String: TokenTotals]) -> (perModel: [String: Decimal], total: Decimal) {
        var out: [String: Decimal] = [:]
        var total: Decimal = 0
        for (model, totals) in byModel {
            let c = cost(model: model, totals: totals)
            out[model] = c
            total += c
        }
        return (out, total)
    }
}
