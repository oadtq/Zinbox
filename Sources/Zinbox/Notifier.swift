import AppKit
import UserNotifications

// Page notifications become macOS notifications. Clicking one brings the
// window forward on that service and tells the page it was clicked.

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private(set) var status: UNAuthorizationStatus = .notDetermined
    /// Every notification handed to macOS, newest last. Read by the test probe.
    private(set) var posted: [[String: String]] = []

    func start() {
        UNUserNotificationCenter.current().delegate = self
        refresh()
    }

    func refresh(_ done: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                self.status = status
                done?()
            }
        }
    }

    /// Asked once there is a service to notify about.
    func askIfNeeded() {
        refresh {
            guard self.status == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                DispatchQueue.main.async { self.refresh() }
            }
        }
    }

    func post(service: Service, title: String, body: String, noteID: String, icon: NSImage) {
        posted.append(["service": service.id.uuidString, "title": title, "body": body, "note": noteID])
        if posted.count > 50 { posted.removeFirst() }

        let content = UNMutableNotificationContent()
        content.title = title
        if title != service.name { content.subtitle = service.name }
        content.body = body
        // Sites like Teams, Slack and WhatsApp play their own sound with each
        // notification. Only add the system sound when this service is muted,
        // so a message makes one sound, not two.
        content.sound = service.audioMuted ? .default : nil
        content.threadIdentifier = service.id.uuidString
        content.userInfo = ["service": service.id.uuidString, "note": noteID]
        if let attachment = attachment(icon, for: service.id) { content.attachments = [attachment] }
        let request = UNNotificationRequest(identifier: "\(service.id.uuidString)-\(noteID.isEmpty ? UUID().uuidString : noteID)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func attachment(_ icon: NSImage, for id: UUID) -> UNNotificationAttachment? {
        guard let tiff = icon.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        // macOS moves attachment files into its own store, so write a fresh copy each time.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zinbox-\(id.uuidString)-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: url)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let service = (info["service"] as? String).flatMap(UUID.init(uuidString:))
        let note = info["note"] as? String
        DispatchQueue.main.async {
            if let service { AppModel.shared.open(service: service, note: note) }
            completionHandler()
        }
    }
}
