import AppKit
import ZinboxCEF

MainActor.assumeIsolated {
    // Chromium requires its NSApplication subclass; WebKit is happy with it too.
    let app = ZBApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = AppDelegate.shared
    app.run()
}
