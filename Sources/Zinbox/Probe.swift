import AppKit
import WebKit

// Test-only remote control. Active only when ZINBOX_PROBE is set, which also
// moves all data to a separate folder. Commands arrive as distributed
// notifications named "app.zinbox.probe" whose object is a JSON string; the
// answer is written as JSON to $ZINBOX_PROBE_OUT.

@MainActor
final class Probe {
    static let shared = Probe()
    private var observer: NSObjectProtocol?
    private let out = ProcessInfo.processInfo.environment["ZINBOX_PROBE_OUT"].map(URL.init(fileURLWithPath:))

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("app.zinbox.probe"), object: nil, queue: .main
        ) { note in
            let text = note.object as? String ?? "{}"
            MainActor.assumeIsolated { Probe.shared.run(text) }
        }
        reply(["ready": true])
    }

    private func run(_ text: String) {
        guard let data = text.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = cmd["cmd"] as? String
        else { return reply(["error": "bad command"]) }
        let model = AppModel.shared
        let index = cmd["index"] as? Int ?? -1
        let target = model.services.indices.contains(index) ? model.services[index].id : model.selected

        switch name {
        case "state":
            reply(state())
        case "add":
            let recipe = Recipes.named(cmd["recipe"] as? String ?? "custom") ?? Recipes.custom
            let added = model.add(recipe: recipe, name: cmd["name"] as? String ?? recipe.name, url: cmd["url"] as? String)
            if let engine = (cmd["engine"] as? String).flatMap(Engine.init) { model.edit(added.id) { $0.engine = engine } }
            reply(state())
        case "select":
            if let target { model.select(target) }
            reply(state())
        case "remove":
            if let target { model.remove(target) }
            reply(state())
        case "enable", "disable":
            if let target { model.setEnabled(target, name == "enable") }
            reply(state())
        case "edit":
            if let target {
                model.edit(target) { s in
                    if let v = cmd["name"] as? String { s.name = v }
                    if let v = cmd["notifications"] as? Bool { s.notifications = v }
                    if let v = cmd["audioMuted"] as? Bool { s.audioMuted = v }
                    if let v = cmd["showBadge"] as? Bool { s.showBadge = v }
                    if let v = cmd["zoom"] as? Double { s.zoom = v }
                    if let v = (cmd["engine"] as? String).flatMap(Engine.init) { s.engine = v }
                }
            }
            reply(state())
        case "dnd":
            model.setDoNotDisturb(cmd["on"] as? Bool ?? !model.doNotDisturb)
            reply(state())
        case "move":
            if let target { model.move(target, to: cmd["to"] as? Int ?? 0) }
            reply(state())
        case "eval":
            if let target, let chromium = model.controllers[target]?.chromium {
                // Chromium returns nothing from ExecuteJavaScript; the script posts its answer back.
                awaitingChromium = true
                chromium.evaluateJavaScript("""
                (async () => { let v; try { v = await (async () => { \(cmd["js"] as? String ?? "") })(); } catch (e) { v = 'error: ' + e; }
                  __zinboxNative(JSON.stringify({ type: 'probe', value: String(v) })); })();
                """)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if self.awaitingChromium { self.awaitingChromium = false; self.reply(["error": "no answer"]) }
                }
                return
            }
            guard let target, let view = model.controllers[target]?.webView else { return reply(["error": "no web view"]) }
            let world: WKContentWorld = (cmd["world"] as? String) == "zinbox" ? Web.world : .page
            view.callAsyncJavaScript(cmd["js"] as? String ?? "", arguments: [:], in: nil, in: world) { result in
                switch result {
                case .success(let value): self.reply(["result": "\(value)"])
                case .failure(let error): self.reply(["error": "\(error)"])
                }
            }
        case "snapshot":
            snapshot(path: cmd["path"] as? String ?? "/tmp/zinbox.png")
        case "show":
            AppDelegate.shared.showWindow()
            reply(state())
        case "hide":
            AppDelegate.shared.main?.window?.performClose(nil)
            reply(state())
        case "click", "drag":
            // Screen point, top-left origin, as reported by "state".
            guard let window = AppDelegate.shared.main?.window?.attachedSheet ?? NSApp.windows.first(where: { $0.isKeyWindow }) ?? AppDelegate.shared.main?.window else { return reply(["error": "no window"]) }
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            func point(_ x: Double, _ y: Double) -> NSPoint {
                window.convertPoint(fromScreen: NSPoint(x: x, y: screenH - y))
            }
            let p = point(cmd["x"] as? Double ?? 0, cmd["y"] as? Double ?? 0)
            let count = cmd["count"] as? Int ?? 1
            func send(_ type: NSEvent.EventType, _ at: NSPoint, _ clicks: Int = 1) {
                if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
                    if NSApp.isActive {
                        NSApp.sendEvent(e)
                    } else if let frame = window.contentView?.superview {
                        // macOS won't activate us while another app holds focus; deliver to the
                        // view under the pointer, as AppKit would after activation.
                        let hit = (type == .leftMouseDown) ? frame.hitTest(at) : Probe.pressed
                        if type == .leftMouseDown { Probe.pressed = hit }
                        if let control = hit as? NSControl {
                            if type == .leftMouseUp { control.performClick(nil); Probe.pressed = nil }
                            return
                        }
                        switch type {
                        case .leftMouseDown: hit?.mouseDown(with: e)
                        case .leftMouseDragged: hit?.mouseDragged(with: e)
                        case .leftMouseUp: hit?.mouseUp(with: e); Probe.pressed = nil
                        default: break
                        }
                    }
                }
            }
            if name == "drag" {
                let q = point(cmd["toX"] as? Double ?? 0, cmd["toY"] as? Double ?? 0)
                send(.leftMouseDown, p)
                let steps = 12
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    send(.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
                }
                send(.leftMouseUp, q)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.reply(self.state()) }
            } else {
                for c in 1...count {
                    send(.leftMouseDown, p, c)
                    send(.leftMouseUp, p, c)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.reply(self.state()) }
            }
        case "menu":
            // The tab's right-click menu: list it, or pick an item by title.
            guard let target, let menu = ServiceMenu.make(for: target) else { return reply(["error": "no menu"]) }
            if let title = cmd["item"] as? String, let i = menu.items.firstIndex(where: { $0.title == title }) {
                menu.performActionForItem(at: i)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reply(self.state()) }
            } else {
                reply(["items": menu.items.map { $0.isSeparatorItem ? "-" : $0.title + ($0.isEnabled ? "" : " (off)") }])
            }
        case "find":
            // A view by accessibility identifier, or a button by title, in any visible window.
            let id = cmd["id"] as? String ?? ""
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            func search(_ v: NSView) -> NSView? {
                if v.accessibilityIdentifier() == id { return v }
                if let b = v as? NSButton, b.title == id { return b }
                for sub in v.subviews { if let f = search(sub) { return f } }
                return nil
            }
            for w in NSApp.windows where w.isVisible {
                if let root = w.contentView?.superview, let v = search(root) {
                    let r = w.convertToScreen(v.convert(v.bounds, to: nil))
                    return reply(["cx": r.midX, "cy": screenH - r.midY, "window": w.title])
                }
            }
            reply(["error": "not found"])
        case "type":
            // Into the first responder of the key-ish window (sheet first).
            let w = AppDelegate.shared.main?.window?.attachedSheet ?? NSApp.keyWindow
            if let field = w?.firstResponder as? NSTextView {
                field.insertText(cmd["text"] as? String ?? "", replacementRange: field.selectedRange())
            }
            reply(["ok": w?.firstResponder.map { "\(type(of: $0))" } ?? "none"])
        case "appearance":
            NSApp.appearance = (cmd["dark"] as? Bool ?? false) ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.reply(self.state()) }
        case "hit":
            let window = AppDelegate.shared.main!.window!
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            let p = window.convertPoint(fromScreen: NSPoint(x: cmd["x"] as? Double ?? 0, y: screenH - (cmd["y"] as? Double ?? 0)))
            let frameView = window.contentView!.superview!
            var chain: [String] = []
            var v = frameView.hitTest(frameView.superview?.convert(p, from: nil) ?? p)
            while let view = v { chain.append(String(describing: type(of: view))); v = view.superview }
            reply(["chain": chain])
        case "key":
            // A key equivalent through the real menu path, e.g. {"key":"2","mods":["cmd"]}.
            let key = cmd["key"] as? String ?? ""
            var flags: NSEvent.ModifierFlags = []
            for m in cmd["mods"] as? [String] ?? [] {
                switch m {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            let window = NSApp.keyWindow ?? AppDelegate.shared.main?.window
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window?.windowNumber ?? 0, context: nil, characters: key,
                                        charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(cmd["code"] as? Int ?? 0)) {
                NSApp.sendEvent(e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.reply(self.state()) }
        case "quit":
            reply(["ok": true])
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case "click-notification":
            if let target { model.open(service: target, note: cmd["note"] as? String) }
            reply(state())
        default:
            reply(["error": "unknown \(name)"])
        }
    }

    static var pressed: NSView?
    private var awaitingChromium = false
    private var outside: [String] = []

    func openedOutside(_ url: URL) { outside.append(url.absoluteString) }

    func chromiumResult(_ value: String) {
        guard awaitingChromium else { return }
        awaitingChromium = false
        reply(["result": value])
    }

    private func state() -> [String: Any] {
        let model = AppModel.shared
        let window = AppDelegate.shared.main?.window
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        func topLeft(_ r: NSRect) -> [String: Double] {
            ["x": r.minX, "y": screenH - r.maxY, "w": r.width, "h": r.height, "cx": r.midX, "cy": screenH - r.midY]
        }
        let frames = AppDelegate.shared.main?.bar.tabScreenFrames() ?? [:]
        let services: [[String: Any]] = model.services.map { s in
            let c = model.controllers[s.id]
            return [
                "id": s.id.uuidString, "name": s.name, "recipe": s.recipe, "enabled": s.enabled, "unread": s.unread,
                "notifications": s.notifications, "audioMuted": s.audioMuted, "zoom": s.zoom, "store": s.storeID.uuidString,
                "hasWebView": c?.hasPage ?? false, "url": c?.currentURL?.absoluteString ?? "",
                "engine": c?.runningEngine?.rawValue ?? "", "wantedEngine": s.effectiveEngine.rawValue,
                "loading": c?.isLoading ?? false, "failure": c?.failure ?? "",
                "paneHidden": c?.pane.isHidden ?? true, "paneInWindow": c?.pane.window != nil,
                "tab": frames[s.id].map(topLeft) ?? [:],
                "pageZoom": c?.webView?.pageZoom ?? 0,
            ]
        }
        var buttons: [String: Any] = [:]
        for b in ["add", "reload", "dnd"] {
            if let r = AppDelegate.shared.main?.bar.buttonScreenFrame(b) { buttons[b] = topLeft(r) }
        }
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> [String: Double]? in
            guard let b = window?.standardWindowButton(type), let w = window else { return nil }
            return topLeft(w.convertToScreen(b.convert(b.bounds, to: nil)))
        }
        return [
            "services": services,
            "selected": model.selected?.uuidString ?? "",
            "dnd": model.doNotDisturb,
            "dockBadge": NSApp.dockTile.badgeLabel ?? "",
            "windowVisible": window?.isVisible ?? false,
            "windowKey": window?.isKeyWindow ?? false,
            "appActive": NSApp.isActive, "keyWindow": NSApp.keyWindow?.title ?? "", "canKey": window?.canBecomeKey ?? false,
            "window": window.map { topLeft($0.frame) } ?? [:],
            "sheet": window?.attachedSheet != nil,
            "buttons": buttons,
            "lights": lights,
            "notifications": Notifier.shared.posted,
            "openedOutside": outside,
            "notificationStatus": Notifier.shared.status.rawValue,
            "firstResponder": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "windows": NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)):\($0.title):\(Int($0.frame.width))x\(Int($0.frame.height))" },
        ]
    }

    /// The window as drawn: AppKit chrome plus each visible page's own snapshot.
    private func snapshot(path: String) {
        guard let window = AppDelegate.shared.main?.window, let frameView = window.contentView?.superview else {
            return reply(["error": "no window"])
        }
        if let sheet = window.attachedSheet, let sv = sheet.contentView?.superview,
           let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
            sv.cacheDisplay(in: sv.bounds, to: srep)
            try? srep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-sheet.png")))
        }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return reply(["error": "no rep"]) }
        frameView.cacheDisplay(in: bounds, to: rep)
        let base = NSImage(size: bounds.size)
        base.addRepresentation(rep)

        let visible = AppModel.shared.services.compactMap { AppModel.shared.controllers[$0.id] }
            .filter { !$0.pane.isHidden && $0.webView != nil && $0.webView?.isHidden == false }
        guard let controller = visible.first, let web = controller.webView else {
            return write(base, path)
        }
        let rect = web.convert(web.bounds, to: frameView)
        web.takeSnapshot(with: nil) { image, _ in
            let final = NSImage(size: bounds.size, flipped: false) { _ in
                base.draw(in: bounds)
                image?.draw(in: rect)
                return true
            }
            self.write(final, path)
        }
    }

    private func write(_ image: NSImage, _ path: String) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return reply(["error": "encode"]) }
        try? png.write(to: URL(fileURLWithPath: path))
        reply(["snapshot": path])
    }

    private func reply(_ value: [String: Any]) {
        guard let out, let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: out, options: .atomic)
    }
}
