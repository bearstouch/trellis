import AppKit
import TrellisCore
import UserNotifications

/// One notification to show (FR-T08). The pane is carried so clicking it can reveal that pane.
public struct DesktopNotification: Equatable, Sendable {
    public let paneID: UUID
    public let title: String
    public let body: String
}

/// Notification Center access; injected so tests never post real notifications.
@MainActor
public protocol DesktopNotifier: AnyObject {
    func post(_ notification: DesktopNotification)
}

/// Posts through `UNUserNotificationCenter`, asking for permission on the first notification rather than at launch.
@MainActor
public final class SystemDesktopNotifier: NSObject, DesktopNotifier, UNUserNotificationCenterDelegate {
    /// Called with the pane of a clicked notification.
    public var onActivate: ((UUID) -> Void)?
    private let center: UNUserNotificationCenter
    private nonisolated static let paneKey = "paneID"

    /// Nil outside an `.app` bundle: Notification Center needs a bundle identity, and `swift run` has none.
    public init?(bundle: Bundle = .main) {
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil else { return nil }
        center = .current()
        super.init()
        center.delegate = self
    }

    public func post(_ notification: DesktopNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = [Self.paneKey: notification.paneID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = center
        Task {
            // Denied or failed authorization drops the notification; the tab's attention label (FR-T06) still shows.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    // The model only posts when the pane isn't in view, so a notification arriving while Trellis is active is still shown.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let raw = response.notification.request.content.userInfo[Self.paneKey] as? String, let paneID = UUID(uuidString: raw)
        else { return }
        await MainActor.run { onActivate?(paneID) }
    }
}
