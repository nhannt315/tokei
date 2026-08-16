import AppKit

/// User's appearance choice: follow the system, or force light/dark.
/// Persisted under a single UserDefaults key, read both from SwiftUI
/// (@AppStorage) and from AppDelegate (a non-view context) via `current`.
/// Mirrors the PercentageMode pattern.
enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return loc("System")
        case .light: return loc("Light")
        case .dark: return loc("Dark")
        }
    }

    /// nil = follow the OS; otherwise force the named appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static let defaultsKey = "appearanceMode"

    static var current: AppearanceMode {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    /// Posted by the Settings picker so the AppDelegate re-applies appearance
    /// to NSApp, the popover, and the main window live.
    static let didChange = Notification.Name("tokei.appearanceChanged")
}
