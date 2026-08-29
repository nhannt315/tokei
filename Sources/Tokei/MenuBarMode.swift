import Foundation

/// What the menu-bar label shows: session quota %, today's cost, or burn rate.
/// Persisted under a single UserDefaults key, read both from SwiftUI
/// (@AppStorage) and from AppState (a non-view context) via `current`.
/// Mirrors the PercentageMode / AppearanceMode pattern.
enum MenuBarMode: String, CaseIterable {
    case quota
    case cost
    case burn

    var label: String {
        switch self {
        case .quota: return loc("menuBarMode.quota")
        case .cost: return loc("menuBarMode.cost")
        case .burn: return loc("menuBarMode.burn")
        }
    }

    static let defaultsKey = "menuBarMode"

    static var current: MenuBarMode {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(MenuBarMode.init(rawValue:)) ?? .quota
    }
}
