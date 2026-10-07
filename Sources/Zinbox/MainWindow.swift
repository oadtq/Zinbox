import AppKit

// The one window: tab bar across the top, the selected service below.
// Every enabled service's pane stays in the window (hidden when not selected),
// so pages keep running exactly as they would in a visible tab.

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let bar = TabBar()
    private let stage = NSView()
    private let empty = EmptyView()
    private let model = AppModel.shared
    private var lights: TrafficLights?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Zinbox"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        // The tab bar sits in the titlebar area, where macOS would otherwise start
        // a window drag before the tabs see the mouse. TabBar moves it on empty space.
        window.isMovable = false
        window.minSize = NSSize(width: 640, height: 420)
        window.backgroundColor = Theme.bar
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let root = RootView()
        root.bar = bar
        root.stage = stage
        root.addSubview(stage)
        root.addSubview(bar)
        stage.addSubview(empty)
        empty.frame = stage.bounds
        empty.autoresizingMask = [.width, .height]
        empty.onAdd = { AddServiceSheet.present() }
        window.contentView = root

        if !window.setFrameUsingName("ZinboxMain") { window.center() }
        window.setFrameAutosaveName("ZinboxMain")

        bar.onSelect = { [weak self] id in self?.model.select(id) }
        bar.onMove = { [weak self] id, index in self?.model.move(id, to: index) }
        bar.menuFor = { id in ServiceMenu.make(for: id) }
        bar.onAdd = { AddServiceSheet.present() }
        bar.onReload = { [weak self] in self?.model.currentController?.reload() }
        bar.onDoNotDisturb = { [weak self] in
            guard let self else { return }
            self.model.setDoNotDisturb(!self.model.doNotDisturb)
        }

        lights = TrafficLights(window: window, height: Theme.barHeight) { [weak self] inset in
            self?.bar.leadingInset = inset
        }

        NotificationCenter.default.addObserver(forName: AppModel.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: Icons.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let services = model.services
        bar.update(services: services, selected: model.selected, doNotDisturb: model.doNotDisturb,
                   canReload: model.current?.enabled == true)
        // Mount every pane, show only the selected one.
        var mounted = Set<ObjectIdentifier>()
        for s in services {
            guard let pane = model.controllers[s.id]?.pane else { continue }
            mounted.insert(ObjectIdentifier(pane))
            if pane.superview !== stage {
                pane.frame = stage.bounds
                pane.autoresizingMask = [.width, .height]
                stage.addSubview(pane, positioned: .below, relativeTo: empty)
            }
            pane.isHidden = s.id != model.selected
        }
        for case let pane as ServicePane in stage.subviews where !mounted.contains(ObjectIdentifier(pane)) {
            pane.removeFromSuperview()
        }
        empty.isHidden = !services.isEmpty
        if let name = model.current?.name {
            window?.title = "Zinbox — \(name)"
        } else {
            window?.title = "Zinbox"
        }
        focusSelected()
    }

    private var focusedService: UUID?

    /// Keyboard focus follows the selected service, so typing goes to its page.
    private func focusSelected() {
        guard focusedService != model.selected else { return }
        focusedService = model.selected
        if let view = model.currentController?.webView, view.window != nil {
            window?.makeFirstResponder(view)
        }
    }

    // MARK: - window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing hides; the services keep running so they can still notify.
        if sender.styleMask.contains(.fullScreen) {
            sender.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { sender.orderOut(nil) }
        } else {
            sender.orderOut(nil)
        }
        return false
    }

    func windowWillEnterFullScreen(_ notification: Notification) { lights?.fullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { lights?.fullScreen = false }
}

// MARK: - Root

@MainActor
private final class RootView: NSView {
    var bar: TabBar!
    var stage: NSView!

    override func layout() {
        super.layout()
        let h = Theme.barHeight
        bar.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        stage.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - h)
    }
}

// MARK: - Empty

@MainActor
private final class EmptyView: NSView {
    var onAdd: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "tray.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 44, weight: .ultraLight))
        icon.contentTintColor = .tertiaryLabelColor
        let head = NSTextField(labelWithString: "Welcome to Zinbox")
        head.font = .systemFont(ofSize: 22, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: "Add WhatsApp, Slack, Teams, Gmail or any website. Each service keeps its own login.")
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 13)
        body.preferredMaxLayoutWidth = 360
        let button = NSButton(title: "Add a Service", target: self, action: #selector(add))
        button.bezelStyle = .push
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.setAccessibilityIdentifier("empty-add")
        let stack = NSStackView(views: [icon, head, body, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = Theme.content.cgColor }
    override var wantsUpdateLayer: Bool { true }

    @objc private func add() { onAdd?() }
}

// MARK: - Traffic lights

/// Centres the close/minimise/zoom buttons in the taller tab bar.
@MainActor
final class TrafficLights: NSObject {
    private weak var window: NSWindow?
    private let height: CGFloat
    private let inset: (CGFloat) -> Void
    private var placing = false
    private var observers: [NSObjectProtocol] = []
    var fullScreen = false {
        didSet { place() }
    }

    init(window: NSWindow, height: CGFloat, inset: @escaping (CGFloat) -> Void) {
        self.window = window
        self.height = height
        self.inset = inset
        super.init()
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeMainNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        if let container = buttons.first?.superview?.superview {
            container.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        place()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    func place() {
        guard !placing, let window else { return }
        let buttons = self.buttons
        guard buttons.count == 3, let titlebar = buttons[0].superview, let container = titlebar.superview else { return }
        if fullScreen || window.styleMask.contains(.fullScreen) {
            inset(12)
            return
        }
        placing = true
        defer { placing = false }
        var frame = container.frame
        if frame.height != height || abs(frame.maxY - window.frame.height) > 0.5 {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        let spacing: CGFloat = 20
        for (i, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = NSPoint(x: 14 + CGFloat(i) * spacing, y: (titlebar.bounds.height - size.height) / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        inset((buttons.last?.frame.maxX ?? 70) + 16)
    }
}
