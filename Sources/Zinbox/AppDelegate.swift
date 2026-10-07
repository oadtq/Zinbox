import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    private(set) var main: MainWindowController?
    private let serviceMenu = NSMenu(title: "Service")
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        Notifier.shared.start()
        let controller = MainWindowController()
        main = controller
        controller.showWindow(nil)
        AppModel.shared.startAll()
        if !AppModel.shared.services.isEmpty { Notifier.shared.askIfNeeded() }
        if Store.testing { Probe.shared.start() }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.save()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @discardableResult
    func showWindow() -> NSWindow? {
        guard let window = main?.window else { return nil }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return window
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let bar = NSMenu()

        let app = NSMenu(title: "Zinbox")
        app.addItem(withTitle: "About Zinbox", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(ClosureItem(title: "Settings…", key: ",") { SettingsWindow.shared.show() })
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Zinbox", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Zinbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: bar)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let spelling = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: "Spelling and Grammar")
        spellingMenu.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spelling.submenu = spellingMenu
        edit.addItem(spelling)
        let subs = NSMenuItem(title: "Substitutions", action: nil, keyEquivalent: "")
        let subsMenu = NSMenu(title: "Substitutions")
        subsMenu.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        subsMenu.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        subsMenu.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        subs.submenu = subsMenu
        edit.addItem(subs)
        add(edit, to: bar)

        let view = NSMenu(title: "View")
        view.addItem(ClosureItem(title: "Reload Service", key: "r") { AppModel.shared.currentController?.reload() })
        let hard = ClosureItem(title: "Reload Ignoring Cache", key: "R") { AppModel.shared.currentController?.webView?.reloadFromOrigin() }
        view.addItem(hard)
        view.addItem(ClosureItem(title: "Go to Home Page", key: "H") { AppModel.shared.currentController?.goHome() })
        view.addItem(.separator())
        view.addItem(ClosureItem(title: "Back", key: "[") { AppModel.shared.currentController?.webView?.goBack() })
        view.addItem(ClosureItem(title: "Forward", key: "]") { AppModel.shared.currentController?.webView?.goForward() })
        view.addItem(.separator())
        view.addItem(ClosureItem(title: "Actual Size", key: "0") { Self.zoom(to: 1) })
        view.addItem(ClosureItem(title: "Zoom In", key: "+") { Self.zoom(by: 0.1) })
        let zoomInAlt = ClosureItem(title: "Zoom In", key: "=") { Self.zoom(by: 0.1) }
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        view.addItem(zoomInAlt)
        view.addItem(ClosureItem(title: "Zoom Out", key: "-") { Self.zoom(by: -0.1) })
        view.addItem(.separator())
        let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        let inspector = ClosureItem(title: "Web Inspector", key: "i") { Self.toggleInspector() }
        inspector.keyEquivalentModifierMask = [.command, .option]
        view.addItem(inspector)
        add(view, to: bar)

        serviceMenu.delegate = self
        add(serviceMenu, to: bar)
        menuNeedsUpdate(serviceMenu)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(ClosureItem(title: "Zinbox") { AppDelegate.shared.showWindow() })
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, to: bar)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        add(help, to: bar)
        NSApp.helpMenu = help
        return bar
    }

    private func add(_ menu: NSMenu, to bar: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
    }

    /// The Service menu follows the current list and selection.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === serviceMenu else { return }
        menu.removeAllItems()
        let model = AppModel.shared
        menu.addItem(ClosureItem(title: "Add Service…", key: "n") { AddServiceSheet.present() })
        menu.addItem(.separator())
        let next = ClosureItem(title: "Next Service", key: "\t") { AppModel.shared.selectNext(1) }
        next.keyEquivalentModifierMask = [.control]
        menu.addItem(next)
        let previous = ClosureItem(title: "Previous Service", key: "\t") { AppModel.shared.selectNext(-1) }
        previous.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(previous)
        let nextAlt = ClosureItem(title: "Next Service", key: "\u{F703}") { AppModel.shared.selectNext(1) }
        nextAlt.keyEquivalentModifierMask = [.command, .option]
        nextAlt.isHidden = true
        nextAlt.allowsKeyEquivalentWhenHidden = true
        menu.addItem(nextAlt)
        let previousAlt = ClosureItem(title: "Previous Service", key: "\u{F702}") { AppModel.shared.selectNext(-1) }
        previousAlt.keyEquivalentModifierMask = [.command, .option]
        previousAlt.isHidden = true
        previousAlt.allowsKeyEquivalentWhenHidden = true
        menu.addItem(previousAlt)
        menu.addItem(.separator())
        for (i, s) in model.services.enumerated() {
            let item = ClosureItem(title: s.name, key: i < 9 ? "\(i + 1)" : "") { AppModel.shared.select(s.id) }
            item.state = s.id == model.selected ? .on : .off
            item.image = Icons.shared.image(for: s).resized(16)
            menu.addItem(item)
        }
        if !model.services.isEmpty { menu.addItem(.separator()) }
        let dnd = ClosureItem(title: "Do Not Disturb", key: "M") { model.setDoNotDisturb(!model.doNotDisturb) }
        dnd.state = model.doNotDisturb ? .on : .off
        menu.addItem(dnd)
        if let current = model.current, let items = ServiceMenu.make(for: current.id)?.items {
            menu.addItem(.separator())
            let header = NSMenuItem(title: current.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }
    }

    // MARK: - View actions

    private static func zoom(by step: Double) {
        guard let s = AppModel.shared.current else { return }
        let z = (s.zoom + step).clamped(0.5, 2.5)
        AppModel.shared.edit(s.id) { $0.zoom = (z * 10).rounded() / 10 }
    }

    private static func zoom(to value: Double) {
        guard let s = AppModel.shared.current else { return }
        AppModel.shared.edit(s.id) { $0.zoom = value }
    }

    private static func toggleInspector() {
        guard let view = AppModel.shared.currentController?.webView else { return }
        let getter = NSSelectorFromString("_inspector")
        guard view.responds(to: getter), let inspector = view.perform(getter)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) { inspector.perform(show) }
    }
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(high, Swift.max(low, self)) }
}

extension NSImage {
    func resized(_ side: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22).addClip()
            self.draw(in: rect)
            return true
        }
        return img
    }
}
