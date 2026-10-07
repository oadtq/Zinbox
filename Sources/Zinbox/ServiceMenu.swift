import AppKit

// The right-click menu on a tab. The Service menu in the menu bar uses the
// same actions on the selected service.

@MainActor
enum ServiceMenu {
    static func make(for id: UUID) -> NSMenu? {
        guard let s = AppModel.shared.service(id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Reload", "arrow.clockwise", enabled: s.enabled) { AppModel.shared.controllers[id]?.reload() })
        menu.addItem(item("Go to Home Page", "house", enabled: s.enabled) { AppModel.shared.controllers[id]?.goHome() })
        menu.addItem(item("Open in Browser", "safari") {
            let url = AppModel.shared.controllers[id]?.webView?.url ?? s.startURL
            if let url { NSWorkspace.shared.open(url) }
        })
        menu.addItem(.separator())
        menu.addItem(item(s.notifications ? "Turn Off Notifications" : "Turn On Notifications",
                          s.notifications ? "bell.slash" : "bell") {
            AppModel.shared.edit(id) { $0.notifications.toggle() }
        })
        menu.addItem(item(s.audioMuted ? "Unmute Audio" : "Mute Audio", s.audioMuted ? "speaker.wave.2" : "speaker.slash") {
            AppModel.shared.edit(id) { $0.audioMuted.toggle() }
        })
        menu.addItem(item(s.enabled ? "Disable Service" : "Enable Service", s.enabled ? "moon.zzz" : "sun.max") {
            AppModel.shared.setEnabled(id, !s.enabled)
        })
        menu.addItem(.separator())
        menu.addItem(item("Edit…", "pencil") { EditServiceSheet.present(id) })
        menu.addItem(item("Remove…", "trash") { confirmRemove(id) })
        return menu
    }

    static func confirmRemove(_ id: UUID) {
        guard let s = AppModel.shared.service(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(s.name)?"
        alert.informativeText = "This signs you out of \(s.name) in Zinbox and deletes its data on this Mac."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        Dialogs.run(alert, in: AppDelegate.shared.main?.window) { response in
            if response == .alertFirstButtonReturn { AppModel.shared.remove(id) }
        }
    }

    private static func item(_ title: String, _ symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureItem(title: title, action: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = enabled
        return item
    }
}

/// A menu item that runs a closure.
final class ClosureItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, key: String = "", action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
