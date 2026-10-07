import AppKit

// Add Service, Edit Service and Settings.

// MARK: - Add

@MainActor
final class AddServiceSheet: NSObject, NSTextFieldDelegate {
    private static var current: AddServiceSheet?

    static func present() {
        guard current == nil, let parent = AppDelegate.shared.showWindow() else { return }
        let sheet = AddServiceSheet()
        current = sheet
        Icons.shared.warm()
        parent.beginSheet(sheet.window) { _ in current = nil }
        sheet.window.makeFirstResponder(sheet.nameField)
    }

    let window: NSWindow
    private var tiles: [Tile] = []
    private var chosen: Recipe = Recipes.all[0]
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let urlRow: NSStackView
    private let addButton = NSButton(title: "Add Service", target: nil, action: nil)
    private var iconObserver: NSObjectProtocol?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        let urlLabel = NSTextField(labelWithString: "URL")
        urlRow = NSStackView(views: [urlLabel, urlField])
        super.init()

        let title = NSTextField(labelWithString: "Add a Service")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Each service gets its own login. Add the same one twice for two accounts.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)

        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        let recipes = Recipes.all + [Recipes.custom]
        var row: [NSView] = []
        for recipe in recipes {
            let tile = Tile(recipe: recipe) { [weak self] tile, double in
                self?.choose(tile.recipe)
                if double { self?.add() }
            }
            tiles.append(tile)
            row.append(tile)
            if row.count == 4 {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty {
            while row.count < 4 { row.append(NSGridCell.emptyContentView) }
            grid.addRow(with: row)
        }

        let nameLabel = NSTextField(labelWithString: "Name")
        nameField.placeholderString = "Name shown on the tab"
        nameField.delegate = self
        nameField.setAccessibilityIdentifier("add-name")
        urlField.placeholderString = "https://example.com"
        urlField.delegate = self
        urlField.setAccessibilityIdentifier("add-url")
        for label in [nameLabel, urlLabel] {
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let nameRow = NSStackView(views: [nameLabel, nameField])
        for r in [nameRow, urlRow] {
            r.orientation = .horizontal
            r.spacing = 8
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(add)
        addButton.keyEquivalent = "\r"
        addButton.setAccessibilityIdentifier("add-confirm")
        let buttons = NSStackView(views: [NSView(), cancel, addButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, subtitle, grid, nameRow, urlRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(18, after: grid)
        stack.setCustomSpacing(18, after: urlRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            urlRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        choose(Recipes.all[0])
        iconObserver = NotificationCenter.default.addObserver(forName: Icons.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tiles.forEach { $0.refreshIcon() } }
        }
    }

    private func choose(_ recipe: Recipe) {
        let previousDefault = defaultName(for: chosen)
        chosen = recipe
        for t in tiles { t.selected = t.recipe.id == recipe.id }
        if nameField.stringValue.isEmpty || nameField.stringValue == previousDefault {
            nameField.stringValue = defaultName(for: recipe)
        }
        urlRow.isHidden = !recipe.isCustom
        if recipe.isCustom {
            window.makeFirstResponder(urlField)
        }
        validate()
    }

    /// "Slack", then "Slack 2" for a second account.
    private func defaultName(for recipe: Recipe) -> String {
        if recipe.isCustom { return "" }
        let names = Set(AppModel.shared.services.map(\.name))
        if !names.contains(recipe.name) { return recipe.name }
        var n = 2
        while names.contains("\(recipe.name) \(n)") { n += 1 }
        return "\(recipe.name) \(n)"
    }

    func controlTextDidChange(_ obj: Notification) {
        if chosen.isCustom, obj.object as? NSTextField === urlField, nameField.stringValue.isEmpty || nameIsAuto,
           let host = Service.parse(urlField.stringValue)?.host() {
            nameField.stringValue = host.replacingOccurrences(of: "www.", with: "")
            nameIsAuto = true
        }
        if obj.object as? NSTextField === nameField { nameIsAuto = false }
        validate()
    }

    private var nameIsAuto = false

    private func validate() {
        let nameOK = !nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        let urlOK = !chosen.isCustom || Service.parse(urlField.stringValue) != nil
        addButton.isEnabled = nameOK && urlOK
    }

    @objc private func add() {
        validate()
        guard addButton.isEnabled else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let url = chosen.isCustom ? Service.parse(urlField.stringValue)?.absoluteString : nil
        AppModel.shared.add(recipe: chosen, name: name, url: url)
        close()
    }

    @objc private func cancel() { close() }

    private func close() {
        window.sheetParent?.endSheet(window)
    }

    /// One service in the grid.
    final class Tile: NSView {
        let recipe: Recipe
        private let pick: (Tile, Bool) -> Void
        private let image = NSImageView()
        var selected = false {
            didSet { needsDisplay = true }
        }

        init(recipe: Recipe, pick: @escaping (Tile, Bool) -> Void) {
            self.recipe = recipe
            self.pick = pick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 74).isActive = true
            widthAnchor.constraint(equalToConstant: 123).isActive = true
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = 7
            image.layer?.masksToBounds = true
            let label = NSTextField(labelWithString: recipe.name)
            label.font = .systemFont(ofSize: 12)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [image, label])
            stack.orientation = .vertical
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: 32),
                image.heightAnchor.constraint(equalToConstant: 32),
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
            ])
            refreshIcon()
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(recipe.name)
            setAccessibilityIdentifier("recipe-\(recipe.id)")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func refreshIcon() { image.image = Icons.shared.image(for: recipe) }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                path.fill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
                path.fill()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) { pick(self, event.clickCount >= 2) }

        override func accessibilityPerformPress() -> Bool {
            pick(self, false)
            return true
        }
    }
}

// MARK: - Edit

@MainActor
final class EditServiceSheet: NSObject {
    private static var current: EditServiceSheet?

    static func present(_ id: UUID) {
        guard current == nil, let service = AppModel.shared.service(id), let parent = AppDelegate.shared.showWindow() else { return }
        let sheet = EditServiceSheet(service)
        current = sheet
        parent.beginSheet(sheet.window) { _ in current = nil }
    }

    let window: NSWindow
    private let id: UUID
    private let isCustom: Bool
    private let nameField: NSTextField
    private let urlField: NSTextField
    private let enabled: NSButton
    private let notifications: NSButton
    private let badge: NSButton
    private let audio: NSButton

    private init(_ s: Service) {
        id = s.id
        isCustom = Recipes.named(s.recipe)?.isCustom ?? true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        nameField = NSTextField(string: s.name)
        urlField = NSTextField(string: s.url ?? s.startURL?.absoluteString ?? "")
        enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
        notifications = NSButton(checkboxWithTitle: "Show notifications", target: nil, action: nil)
        badge = NSButton(checkboxWithTitle: "Show unread count on the tab and in the Dock", target: nil, action: nil)
        audio = NSButton(checkboxWithTitle: "Mute audio", target: nil, action: nil)
        super.init()
        enabled.state = s.enabled ? .on : .off
        notifications.state = s.notifications ? .on : .off
        badge.state = s.showBadge ? .on : .off
        audio.state = s.audioMuted ? .on : .off

        let title = NSTextField(labelWithString: "Edit \(s.name)")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail

        func row(_ label: String, _ field: NSTextField) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 40).isActive = true
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            let r = NSStackView(views: [l, field])
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }
        if !isCustom {
            urlField.placeholderString = Recipes.named(s.recipe)?.url.absoluteString
            urlField.stringValue = s.url ?? ""
        }
        let nameRow = row("Name", nameField)
        let urlRow = row("URL", urlField)
        let grid = NSStackView(views: [nameRow, urlRow])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8

        let checks = NSStackView(views: [enabled, notifications, badge, audio])
        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 6

        let remove = NSButton(title: "Remove Service…", target: self, action: #selector(remove))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [remove, NSView(), cancel, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, grid, checks, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            nameRow.widthAnchor.constraint(equalTo: buttons.widthAnchor),
            urlRow.widthAnchor.constraint(equalTo: buttons.widthAnchor),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let rawURL = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        var url: String?
        if !rawURL.isEmpty {
            guard let parsed = Service.parse(rawURL) else { return NSSound.beep() }
            url = parsed.absoluteString
        } else if isCustom {
            return NSSound.beep()
        }
        AppModel.shared.edit(id) { s in
            if !name.isEmpty { s.name = name }
            s.url = url
            s.enabled = self.enabled.state == .on
            s.notifications = self.notifications.state == .on
            s.showBadge = self.badge.state == .on
            s.audioMuted = self.audio.state == .on
        }
        close()
    }

    @objc private func remove() {
        let id = self.id
        close()
        DispatchQueue.main.async { ServiceMenu.confirmRemove(id) }
    }

    @objc private func cancel() { close() }

    private func close() { window.sheetParent?.endSheet(window) }
}

// MARK: - Settings

@MainActor
final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private let dnd = NSButton(checkboxWithTitle: "Do Not Disturb — pause all notifications", target: nil, action: nil)
    private let dock = NSButton(checkboxWithTitle: "Show the total unread count on the Dock icon", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")

    func show() {
        if window == nil { build() }
        sync()
        Notifier.shared.refresh { [weak self] in self?.sync() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        dnd.target = self
        dnd.action = #selector(toggled)
        dock.target = self
        dock.action = #selector(toggled)
        status.textColor = .secondaryLabelColor
        let openNotifications = NSButton(title: "Notification Settings…", target: self, action: #selector(openSystemSettings))
        let notifRow = NSStackView(views: [status, NSView(), openNotifications])
        notifRow.orientation = .horizontal
        let reveal = NSButton(title: "Show Data Folder", target: self, action: #selector(reveal))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSTextField(labelWithString: "Zinbox \(version)")
        about.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [about, NSView(), reveal])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [dnd, dock, notifRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(24, after: notifRow)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            notifRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        w.contentView = content
        window = w
        NotificationCenter.default.addObserver(forName: AppModel.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private func sync() {
        dnd.state = AppModel.shared.doNotDisturb ? .on : .off
        dock.state = AppModel.shared.dockBadge ? .on : .off
        switch Notifier.shared.status {
        case .authorized, .provisional, .ephemeral: status.stringValue = "macOS notifications are allowed."
        case .denied: status.stringValue = "macOS notifications are turned off for Zinbox."
        default: status.stringValue = "Zinbox hasn't asked to notify you yet."
        }
    }

    @objc private func toggled() {
        AppModel.shared.setDoNotDisturb(dnd.state == .on)
        AppModel.shared.setDockBadge(dock.state == .on)
    }

    @objc private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([Store.file]) }
}
