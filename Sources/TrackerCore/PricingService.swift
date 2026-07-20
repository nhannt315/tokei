import Foundation

/// Loads pricing with a cascade: cached download (App Support, if < 24h old)
/// → bundled snapshot. `refresh()` fetches from LiteLLM, filters to claude
/// keys, persists, and returns the fresh catalog; on failure the cached or
/// bundled catalog stands.
public struct PricingService: Sendable {
    public static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    public let cacheURL: URL
    public let maxCacheAge: TimeInterval

    public init(cacheURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tokei/pricing.json"),
        maxCacheAge: TimeInterval = 24 * 3600) {
        self.cacheURL = cacheURL
        self.maxCacheAge = maxCacheAge
    }

    /// True when there is no cache or it is older than `maxCacheAge`.
    public func cacheIsStale(now: Date = Date()) -> Bool {
        guard let mtime = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date else {
            return true
        }
        return now.timeIntervalSince(mtime) > maxCacheAge
    }

    /// Cached download if fresh, else bundled snapshot. Never fails: the
    /// bundled snapshot is checked in.
    public func load(now: Date = Date()) throws -> PricingCatalog {
        if !cacheIsStale(now: now), let data = try? Data(contentsOf: cacheURL) {
            if let catalog = try? PricingCatalog(litellmJSON: data), !catalog.models.isEmpty {
                return catalog
            }
        }
        return try loadBundled()
    }

    public func loadBundled() throws -> PricingCatalog {
        guard let url = Bundle.module.url(forResource: "DefaultPricing", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try PricingCatalog(litellmJSON: try Data(contentsOf: url))
    }

    /// Fetch remote pricing, filter to claude keys (source is ~10MB), persist,
    /// return the catalog. Throws on network/decode failure — callers keep
    /// their current catalog.
    public func refresh() async throws -> PricingCatalog {
        let (data, response) = try await URLSession.shared.data(from: Self.remoteURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let filtered = root.filter { $0.key.contains("claude") }
        let filteredData = try JSONSerialization.data(withJSONObject: filtered)
        let catalog = try PricingCatalog(litellmJSON: filteredData)
        guard !catalog.models.isEmpty else { throw CocoaError(.propertyListReadCorrupt) }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try filteredData.write(to: cacheURL, options: .atomic)
        return catalog
    }
}
