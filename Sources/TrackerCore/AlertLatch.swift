import Foundation

/// Pure fire/re-arm decisions for the quota and daily-cost alerts. The caller
/// owns the latch flags and the reset boundaries (window reset, midnight); this
/// only answers "should I fire now?" so the logic is testable without any
/// UserNotifications or AppState plumbing.
public enum AlertLatch {
    /// Fire the quota-remaining alert when remaining has crossed below the
    /// threshold and we have not already fired for this window. `thresholdPct`
    /// of 0 disables the alert. Compares on the transition (guarded by
    /// `alreadyFired`), not the level, so hovering at the boundary won't spam.
    public static func shouldFireQuota(remainingPct: Double, thresholdPct: Double,
                                       alreadyFired: Bool) -> Bool {
        guard thresholdPct > 0, !alreadyFired else { return false }
        return remainingPct < thresholdPct
    }

    /// Fire the daily-cost alert when today's cost has crossed at or above the
    /// dollar threshold and we have not already fired today. `thresholdDollars`
    /// of 0 disables the alert.
    public static func shouldFireCost(todayDollars: Decimal, thresholdDollars: Decimal,
                                      alreadyFired: Bool) -> Bool {
        guard thresholdDollars > 0, !alreadyFired else { return false }
        return todayDollars >= thresholdDollars
    }
}
