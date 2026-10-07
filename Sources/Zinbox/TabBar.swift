import AppKit

// The strip across the top of the window: one tab per service, then reload,
// Do Not Disturb and add. Tabs drag to reorder. Empty space drags the window.

@MainActor
final class TabBar: NSView {
    var onSelect: ((UUID) -> Void)?
    var onMove: ((UUID, Int) -> Void)?
    var menuFor: ((UUID) -> NSMenu?)?
    var onAdd: (() -> Void)?
    var onReload: (() -> Void)?
    var onDoNotDisturb: (() -> Void)?

    /// Room left for the traffic lights.
    var leadingInset: CGFloat = 84 {
        didSet { needsLayout = true }
    }

    private var tabs: [TabView] = []
    private let tabsClip = FlippedView()
    private let actions = NSStackView()
    private let reloadButton = BarButton(symbol: "arrow.clockwise", tip: "Reload this service (⌘R)")
    private let dndButton = BarButton(symbol: "bell", tip: "Do Not Disturb (⇧⌘M)")
    private let addButton = BarButton(symbol: "plus", tip: "Add a service (⌘N)")
    private var scroll: CGFloat = 0
    private var drag: (tab: TabView, startX: CGFloat, mouseX: CGFloat, moved: Bool, target: Int)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        tabsClip.wantsLayer = true
        tabsClip.layer?.masksToBounds = true
        addSubview(tabsClip)

        reloadButton.target = self
        reloadButton.action = #selector(reloadTapped)
        reloadButton.setAccessibilityLabel("Reload")
        dndButton.target = self
        dndButton.action = #selector(dndTapped)
        dndButton.setAccessibilityLabel("Do Not Disturb")
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.setAccessibilityLabel("Add a service")
        actions.orientation = .horizontal
        actions.spacing = 2
        for b in [reloadButton, dndButton, addButton] { actions.addArrangedSubview(b) }
        addSubview(actions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bar.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - content

    func update(services: [Service], selected: UUID?, doNotDisturb: Bool, canReload: Bool) {
        var byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var next: [TabView] = []
        for s in services {
            let tab = byID.removeValue(forKey: s.id) ?? {
                let t = TabView(id: s.id, bar: self)
                tabsClip.addSubview(t)
                return t
            }()
            tab.configure(service: s, icon: Icons.shared.image(for: s), selected: s.id == selected)
            next.append(tab)
        }
        for leftover in byID.values { leftover.removeFromSuperview() }
        tabs = next
        dndButton.symbol = doNotDisturb ? "bell.slash.fill" : "bell"
        dndButton.contentTintColor = doNotDisturb ? .systemOrange : nil
        dndButton.toolTip = doNotDisturb ? "Do Not Disturb is on — notifications are paused (⇧⌘M)" : "Do Not Disturb (⇧⌘M)"
        reloadButton.isEnabled = canReload
        if drag == nil { needsLayout = true }
        revealSelected()
    }

    override func layout() {
        super.layout()
        let actionsSize = actions.fittingSize
        actions.frame = NSRect(x: bounds.width - actionsSize.width - 10, y: (bounds.height - actionsSize.height) / 2,
                               width: actionsSize.width, height: actionsSize.height)
        tabsClip.frame = NSRect(x: leadingInset, y: 0, width: max(0, actions.frame.minX - 8 - leadingInset), height: bounds.height)
        layoutTabs(animated: false)
    }

    private var laidOut: [ObjectIdentifier: NSRect] = [:]

    private func layoutTabs(animated: Bool) {
        let available = tabsClip.bounds.width
        let gap: CGFloat = 4
        let gaps = gap * CGFloat(max(0, tabs.count - 1))
        // Shorten names first; only drop them when even short names don't fit.
        var cap: CGFloat = 150
        while cap > 56 && tabs.reduce(0, { $0 + $1.width(textCap: cap) }) + gaps > available { cap -= 6 }
        let compact = tabs.reduce(0, { $0 + $1.width(textCap: cap) }) + gaps > available
        var x: CGFloat = 0
        var frames: [NSRect] = []
        for tab in tabs {
            tab.compact = compact
            let w = compact ? TabView.compactWidth : tab.width(textCap: cap)
            frames.append(NSRect(x: x, y: (bounds.height - TabView.height) / 2, width: w, height: TabView.height))
            x += w + gap
        }
        let content = max(0, x - gap)
        scroll = max(0, min(scroll, content - available))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.18 : 0
            ctx.allowsImplicitAnimation = animated
            for (tab, frame) in zip(tabs, frames) where tab !== drag?.tab {
                let f = frame.offsetBy(dx: -scroll, dy: 0)
                laidOut[ObjectIdentifier(tab)] = f
                if animated { tab.animator().frame = f } else { tab.frame = f }
            }
        }
    }

    private func revealSelected() {
        guard let tab = tabs.first(where: { $0.isSelected }) else { return }
        layoutSubtreeIfNeeded()
        let f = tab.frame.offsetBy(dx: scroll, dy: 0)
        let width = tabsClip.bounds.width
        if f.minX - scroll < 0 { scroll = f.minX } else if f.maxX - scroll > width { scroll = f.maxX - width }
        layoutTabs(animated: false)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scroll -= delta
        layoutTabs(animated: false)
    }

    // MARK: - window drag on empty space

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
            return
        }
        // The window itself is not movable (so dragging a tab can't move it);
        // allow it just for this drag on empty space.
        window.isMovable = true
        window.performDrag(with: event)
        window.isMovable = false
    }

    // MARK: - tab events

    fileprivate func tabMouseDown(_ tab: TabView, _ event: NSEvent) {
        onSelect?(tab.id)
        drag = (tab, tab.frame.minX, event.locationInWindow.x, false, tabs.firstIndex { $0 === tab } ?? 0)
    }

    fileprivate func tabMouseDragged(_ event: NSEvent) {
        guard var d = drag else { return }
        let dx = event.locationInWindow.x - d.mouseX
        if !d.moved && abs(dx) < 4 { return }
        if !d.moved {
            d.moved = true
            d.tab.layer?.zPosition = 10
            d.tab.dragging = true
        }
        let maxX = tabsClip.bounds.width - d.tab.frame.width
        let x = max(0, min(maxX, d.startX + dx))
        d.tab.setFrameOrigin(NSPoint(x: x, y: d.tab.frame.minY))

        // Where would it land? The leading edge when moving left, the trailing
        // edge when moving right, against each other tab's centre.
        let edge = (dx < 0 ? x : x + d.tab.frame.width) + scroll
        var target = 0
        for other in tabs where other !== d.tab {
            let f = laidOut[ObjectIdentifier(other)] ?? other.frame
            if edge > f.midX + scroll { target += 1 }
        }
        let others = tabs.filter { $0 !== d.tab }
        if target != d.target {
            d.target = target
            var order = others
            order.insert(d.tab, at: target)
            tabs = order
            drag = d
            layoutTabs(animated: true)
        }
        drag = d
    }

    fileprivate func tabMouseUp(_ event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        d.tab.dragging = false
        d.tab.layer?.zPosition = 0
        if d.moved {
            onMove?(d.tab.id, d.target)
        }
        layoutTabs(animated: true)
    }

    fileprivate func tabMenu(_ tab: TabView) -> NSMenu? { menuFor?(tab.id) }
    fileprivate func tabPressed(_ tab: TabView) { onSelect?(tab.id) }

    @objc private func reloadTapped() { onReload?() }
    @objc private func dndTapped() { onDoNotDisturb?() }
    @objc private func addTapped() { onAdd?() }

    /// For the test probe: where each tab is, in screen coordinates.
    func tabScreenFrames() -> [UUID: NSRect] {
        var out: [UUID: NSRect] = [:]
        guard let window else { return out }
        for tab in tabs {
            out[tab.id] = window.convertToScreen(tab.convert(tab.bounds, to: nil))
        }
        return out
    }

    func buttonScreenFrame(_ name: String) -> NSRect? {
        let b: NSButton? = ["add": addButton, "reload": reloadButton, "dnd": dndButton][name]
        guard let b, let window else { return nil }
        return window.convertToScreen(b.convert(b.bounds, to: nil))
    }
}

// MARK: - Tab

@MainActor
private final class TabView: NSView {
    static let height: CGFloat = 30
    static let compactWidth: CGFloat = 40
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    let id: UUID
    private unowned let bar: TabBar
    private(set) var isSelected = false
    private var title = ""
    private var icon: NSImage?
    private var unread = 0
    private var showBadge = true
    private var enabled = true
    private var muted = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    var compact = false {
        didSet { if compact != oldValue { needsDisplay = true; toolTip = compact ? title : nil } }
    }
    var dragging = false {
        didSet { needsDisplay = true }
    }

    init(id: UUID, bar: TabBar) {
        self.id = id
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(service: Service, icon: NSImage, selected: Bool) {
        let changed = title != service.name || self.icon !== icon || isSelected != selected || unread != service.unread
            || showBadge != service.showBadge || enabled != service.enabled || muted != service.audioMuted
        title = service.name
        self.icon = icon
        isSelected = selected
        unread = service.unread
        showBadge = service.showBadge
        enabled = service.enabled
        muted = service.audioMuted
        if compact { toolTip = title }
        setAccessibilityLabel(service.name)
        setAccessibilityValue(selected ? 1 : 0)
        setAccessibilityHelp(service.unread > 0 ? "\(service.unread) unread" : nil)
        setAccessibilityIdentifier("tab-\(service.id.uuidString)")
        if changed {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    func width(textCap: CGFloat) -> CGFloat {
        let natural = ceil((title as NSString).size(withAttributes: [.font: Self.font]).width)
        let text = min(textCap, natural)
        if text < natural { toolTip = title } else if !compact { toolTip = nil }
        return 10 + 20 + 8 + text + (muted ? 18 : 0) + 12
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        bar.tabMouseDown(self, event)
    }
    override func mouseDragged(with event: NSEvent) { bar.tabMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { bar.tabMouseUp(event) }

    override func menu(for event: NSEvent) -> NSMenu? { bar.tabMenu(self) }

    override func accessibilityPerformPress() -> Bool {
        bar.tabPressed(self)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        if isSelected || dragging {
            Theme.tabSelected.setFill()
            shape.fill()
            Theme.tabSelectedEdge.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if hovering {
            Theme.tabHover.setFill()
            shape.fill()
        }

        let alpha: CGFloat = enabled ? 1 : 0.4
        let iconRect = NSRect(x: compact ? (bounds.width - 20) / 2 : 10, y: (bounds.height - 20) / 2, width: 20, height: 20)
        if let icon {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: iconRect, xRadius: 5, yRadius: 5).addClip()
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }

        if !compact {
            let color: NSColor = isSelected ? .labelColor : .secondaryLabelColor
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.font, .foregroundColor: color.withAlphaComponent(enabled ? 1 : 0.5), .paragraphStyle: style,
            ]
            let textX = iconRect.maxX + 8
            let textW = bounds.width - textX - 12 - (muted ? 18 : 0)
            let h = (title as NSString).size(withAttributes: attrs).height
            (title as NSString).draw(in: NSRect(x: textX, y: (bounds.height - h) / 2, width: textW, height: h), withAttributes: attrs)
            if muted, let glyph = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Muted") {
                let tinted = glyph.withSymbolConfiguration(.init(pointSize: 10, weight: .medium).applying(.init(paletteColors: [.secondaryLabelColor])))
                tinted?.draw(in: NSRect(x: bounds.width - 12 - 13, y: (bounds.height - 12) / 2, width: 13, height: 12))
            }
        }

        if showBadge && unread > 0 && enabled {
            let text = unread > 99 ? "99+" : "\(unread)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let w = max(15, size.width + 8)
            let badge = NSRect(x: iconRect.maxX - w / 2 - 1, y: iconRect.minY - 6, width: w, height: 15)
            let pill = NSBezierPath(roundedRect: badge, xRadius: 7.5, yRadius: 7.5)
            Theme.bar.setStroke()
            pill.lineWidth = 3
            pill.stroke()
            Theme.badge.setFill()
            pill.fill()
            (text as NSString).draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Bits

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Empty space between and after the tabs drags the window too.
        superview?.mouseDown(with: event)
    }
}

@MainActor
final class BarButton: NSButton {
    var symbol: String {
        didSet { image = Self.image(symbol) }
    }

    init(symbol: String, tip: String) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 28))
        image = Self.image(symbol)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        contentTintColor = nil
        showsBorderOnlyWhileMouseInside = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static func image(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
}
