import SwiftUI
import TrackerCore

/// Localized string from this module's bundle. SwiftPM puts localized `.strings`
/// in `Bundle.module` (not `.main`), so every non-SwiftUI lookup must name it.
/// SwiftUI `Text` sites pass `bundle: .module` directly instead.
func loc(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }

/// Quota status → bar/label tint. Green healthy, orange ≥70% used, red ≥90%.
enum QuotaStatus {
    case healthy, warning, critical

    init(utilization u: Double) {
        self = u >= 0.9 ? .critical : (u >= 0.7 ? .warning : .healthy)
    }

    var color: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// Compact token count: 3_400_000 → "3.4M", 12_000 → "12.0K".
func tokenString(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
    default:           return "\(n)"
    }
}

/// Human bucket title, shared with the window. "Session" / "Week" short forms.
func bucketShortTitle(_ key: String) -> String {
    switch key {
    case "five_hour", "session": return loc("Session")
    case "seven_day", "weekly_all": return loc("Week")
    default:
        if key.contains(":"), let name = key.split(separator: ":").last {
            return String(localized: "Week · \(String(name))", bundle: .module)
        }
        return key
    }
}
