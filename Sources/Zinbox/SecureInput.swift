import AppKit
import Carbon

// macOS Secure Input blocks keyboard tools that watch typing — Vietnamese,
// Chinese and other input methods like EVKey or OpenKey — in every app while
// any app has it on. Browsers turn it on for password fields. Chromium
// doesn't always turn it off again (after a sign-in navigates away, or when
// the tab is switched mid-password), which left it on for the whole app.
//
// So Zinbox owns the rule: Secure Input may only be on while a password
// field has focus in the visible Chromium tab, with Zinbox active. Pages
// report their password focus; anything else switches it off.

@MainActor
enum SecureInput {
    /// Chromium services whose page has a password field focused.
    private static var passwordFocused: Set<UUID> = []
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (NSApplication.didBecomeActiveNotification, nil),
            (NSApplication.didResignActiveNotification, nil),
            (NSWindow.didBecomeKeyNotification, nil),
            (NSWindow.didResignKeyNotification, nil),
            (AppModel.changed, nil),
        ]
        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { reconcileSoon() }
            })
        }
    }

    static func setPasswordFocused(_ service: UUID, _ on: Bool) {
        if on { passwordFocused.insert(service) } else { passwordFocused.remove(service) }
        reconcileSoon()
    }

    static func forget(_ service: UUID) {
        passwordFocused.remove(service)
        reconcileSoon()
    }

    /// After the current event, and again a moment later: Chromium switches
    /// Secure Input on asynchronously, sometimes after the page's own report.
    private static func reconcileSoon() {
        DispatchQueue.main.async { reconcile() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reconcile() }
    }

    static func reconcile() {
        guard IsSecureEventInputEnabled() else { return }
        let model = AppModel.shared
        let window = AppDelegate.shared.main?.window
        let current = model.selected.flatMap { model.controllers[$0] }
        // WebKit balances its own Secure Input correctly: leave its pages alone.
        let pageAllows = current?.webView != nil
            || (current?.chromium != nil && model.selected.map(passwordFocused.contains) == true)
        let allowed = NSApp.isActive && window?.isKeyWindow == true && pageAllows
        guard !allowed else { return }
        // Secure Input is counted per process: release every leftover hold.
        var tries = 0
        while IsSecureEventInputEnabled() && tries < 16 {
            DisableSecureEventInput()
            tries += 1
        }
    }
}
