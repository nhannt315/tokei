import Foundation

/// Fetches remaining quota from the (community-documented) OAuth usage
/// endpoint. Tolerant decode: any top-level object carrying a numeric
/// "utilization" becomes a bucket; unknown fields are ignored.
public struct QuotaClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public enum FetchError: Error {
        case tokenExpired          // HTTP 401
        case http(Int)
        case network(String)
        case badResponse
    }

    public init() {}

    public func fetch(token: String) async -> Result<QuotaSnapshot, FetchError> {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.badResponse) }
        switch http.statusCode {
        case 200: break
        case 401: return .failure(.tokenExpired)
        default: return .failure(.http(http.statusCode))
        }
        guard let snapshot = Self.decode(data, fetchedAt: Date()) else {
            return .failure(.badResponse)
        }
        return .success(snapshot)
    }

    /// Exposed for fixture checks. Schema captured from a live probe
    /// (2026-07-20): utilization/percent values are 0…100; the `limits` array
    /// is the richest source (session, weekly_all, model-scoped weekly caps).
    /// Falls back to the top-level `five_hour`/`seven_day` objects if `limits`
    /// is absent (schema drift tolerance).
    public static func decode(_ data: Data, fetchedAt: Date) -> QuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var buckets: [QuotaBucket] = []

        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let kind = entry["kind"] as? String,
                      let percent = number(entry["percent"]) else { continue }
                var key = kind
                if let scope = entry["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String {
                    key += ":\(name)"
                }
                buckets.append(QuotaBucket(key: key,
                                           utilization: clamp01(percent / 100.0),
                                           resetsAt: parseResetsAt(entry["resets_at"])))
            }
        }
        if buckets.isEmpty {
            for (key, value) in root {
                guard let dict = value as? [String: Any],
                      let percent = number(dict["utilization"]) else { continue }
                buckets.append(QuotaBucket(key: key,
                                           utilization: clamp01(percent / 100.0),
                                           resetsAt: parseResetsAt(dict["resets_at"])))
            }
        }
        guard !buckets.isEmpty else { return nil }
        // Stable order: session/5h window first, then weekly, scoped caps last.
        let rank = ["session": 0, "five_hour": 0, "weekly_all": 1, "seven_day": 1]
        buckets.sort { (rank[$0.key] ?? 2, $0.key) < (rank[$1.key] ?? 2, $1.key) }
        return QuotaSnapshot(buckets: buckets, fetchedAt: fetchedAt)
    }

    private static func number(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }

    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    private static func parseResetsAt(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            // Live endpoint sends 6-digit fractional seconds
            // ("2026-07-20T09:49:59.995225+00:00") — beyond ISO8601DateFormatter.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
            return df.date(from: s)
        }
        if let epoch = any as? Double { return Date(timeIntervalSince1970: epoch) }
        return nil
    }
}
