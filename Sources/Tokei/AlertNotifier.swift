import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter for the quota/cost alerts.
/// Authorization is requested lazily before the first notification (the enable
/// toggle defaults on, so there is no reliable "user turned it on" moment).
/// A denied/undetermined-then-denied state degrades silently: the feature just
/// does nothing, with no repeated prompts and no crash.
@MainActor
final class AlertNotifier {
    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool?   // nil = not yet asked this launch

    /// Post a notification, requesting authorization first if needed. No-op when
    /// authorization is (or becomes) denied.
    func notify(title: String, body: String) async {
        guard await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// Resolve authorization once per launch: honor an existing decision, else
    /// prompt. Returns whether we may post.
    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .denied:
            authorized = false
        default:   // .notDetermined
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return authorized!
    }
}
