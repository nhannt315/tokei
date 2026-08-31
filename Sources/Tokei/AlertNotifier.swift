import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter for the quota/cost alerts.
/// Authorization is requested lazily before the first notification (the enable
/// toggle defaults on, so there is no reliable "user turned it on" moment).
/// A denied/undetermined-then-denied state degrades silently: the feature just
/// does nothing, with no repeated prompts and no crash.
///
/// The center is fetched fresh via `.current()` inside each async call rather
/// than held as a stored property: UNUserNotificationCenter is non-Sendable, and
/// under strict concurrency a stored `self.center` would be "sent" across the
/// await boundary (a data-race error in release builds). `.current()` returns
/// the process-wide shared instance, so re-fetching is free and correct.
@MainActor
final class AlertNotifier {
    private var authorized: Bool?   // nil = not yet asked this launch

    /// Post a notification, requesting authorization first if needed. No-op when
    /// authorization is (or becomes) denied.
    func notify(title: String, body: String) async {
        guard await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Resolve authorization once per launch: honor an existing decision, else
    /// prompt. Returns whether we may post.
    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        switch await currentAuthorizationStatus() {
        case .authorized, .provisional:
            authorized = true
        case .denied:
            authorized = false
        default:   // .notDetermined
            authorized = await requestAuthorization()
        }
        return authorized!
    }

    /// Fetch just the Sendable authorization status via the completion-handler
    /// API, so the non-Sendable UNNotificationSettings never escapes this call.
    private func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings {
                continuation.resume(returning: $0.authorizationStatus)
            }
        }
    }

    /// Request alert authorization; returns whether it was granted (Bool is
    /// Sendable, so nothing non-Sendable crosses the boundary).
    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}
