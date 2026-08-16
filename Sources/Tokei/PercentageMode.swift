import Foundation

/// Whether percentages are shown as quota *remaining* or *used*.
/// The model stores `utilization` (0…1 used fraction); remaining is `1 - utilization`.
/// Persisted under a single UserDefaults key, read both from SwiftUI (@AppStorage)
/// and from AppState (a non-view context) via `current`.
enum PercentageMode: String, CaseIterable {
    case remaining
    case used

    var label: String { self == .remaining ? loc("Remaining") : loc("Used") }

    /// Convert a used-fraction (0…1) into the fraction to display.
    func fraction(usedUtilization u: Double) -> Double { self == .remaining ? 1 - u : u }

    static let defaultsKey = "percentageMode"

    static var current: PercentageMode {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PercentageMode.init(rawValue:)) ?? .remaining
    }
}
