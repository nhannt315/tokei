import Foundation

/// Per-token USD rates for one model, from LiteLLM's pricing JSON.
public struct ModelPricing: Sendable {
    public let input: Decimal
    public let output: Decimal
    public let cacheRead: Decimal
    public let cacheWrite5m: Decimal
    public let cacheWrite1h: Decimal

    /// Missing cache-write rates fall back to Anthropic's documented
    /// multipliers: 5m = 1.25 × input, 1h = 2 × input.
    public init(input: Decimal, output: Decimal, cacheRead: Decimal?,
                cacheWrite5m: Decimal?, cacheWrite1h: Decimal?) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? 0
        self.cacheWrite5m = cacheWrite5m ?? input * Decimal(1.25)
        self.cacheWrite1h = cacheWrite1h ?? input * 2
    }
}

/// modelId → pricing, with prefix fallback for dated model ids
/// ("claude-sonnet-5-20260203" → "claude-sonnet-5").
public struct PricingCatalog: Sendable {
    public let models: [String: ModelPricing]

    public init(models: [String: ModelPricing]) {
        self.models = models
    }

    /// Decode LiteLLM-shaped JSON: { "claude-x": { "input_cost_per_token": … } }.
    /// Per-entry tolerant: entries missing required rates are skipped, not fatal.
    /// Doubles like 5e-06 are routed through their shortest string form so the
    /// resulting Decimal is exact.
    public init(litellmJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var out: [String: ModelPricing] = [:]
        for (key, value) in root {
            guard let entry = value as? [String: Any],
                  let input = Self.decimal(entry["input_cost_per_token"]),
                  let output = Self.decimal(entry["output_cost_per_token"]) else { continue }
            out[key] = ModelPricing(
                input: input,
                output: output,
                cacheRead: Self.decimal(entry["cache_read_input_token_cost"]),
                cacheWrite5m: Self.decimal(entry["cache_creation_input_token_cost"]),
                cacheWrite1h: Self.decimal(entry["cache_creation_input_token_cost_above_1hr"])
            )
        }
        models = out
    }

    private static func decimal(_ any: Any?) -> Decimal? {
        guard let d = any as? Double else { return nil }
        return Decimal(string: "\(d)")
    }

    /// Exact match first, then the longest catalog key that prefixes the model id.
    public func pricing(for model: String) -> ModelPricing? {
        if let exact = models[model] { return exact }
        let candidate = models.keys
            .filter { model.hasPrefix($0) }
            .max { $0.count < $1.count }
        return candidate.map { models[$0]! }
    }
}
