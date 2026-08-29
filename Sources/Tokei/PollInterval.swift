import Foundation

/// How often the quota network poll runs. Only the OAuth quota refresh and the
/// (self-throttled) update check are paced by this; usage/cost still update
/// live via file events. Persisted under a single UserDefaults key, read from
/// SwiftUI (@AppStorage) and from AppState's poll loop via `currentSeconds`.
enum PollInterval: Int, CaseIterable {
    case oneMin = 60
    case fiveMin = 300
    case fifteenMin = 900
    case thirtyMin = 1800

    /// Localized minute label, e.g. "5 min".
    var label: String {
        String(localized: "\(rawValue / 60) min", bundle: .l10n)
    }

    static let defaultsKey = "pollIntervalSeconds"

    /// Seconds between polls: stored value, defaulting to 5 min, floored at 60s
    /// so a tampered default can't hammer the endpoint.
    static var currentSeconds: Int {
        let stored = UserDefaults.standard.integer(forKey: defaultsKey)   // 0 when unset
        return max(60, stored == 0 ? 300 : stored)
    }
}
