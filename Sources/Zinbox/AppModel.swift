import AppKit
import WebKit

// The list of services, which one is on screen, and the web views behind them.
// Views observe `AppModel.changed` and redraw from here.

@MainActor
final class AppModel: ServiceControllerDelegate {
    static let shared = AppModel()
    static let changed = Notification.Name("ZinboxModelChanged")

    private(set) var services: [Service] = []
    private(set) var selected: UUID?
    private(set) var doNotDisturb = false
    private(set) var dockBadge = true
    private(set) var controllers: [UUID: ServiceController] = [:]
    private var saveWork: DispatchWorkItem?

    private init() {
        let snap = Store.load()
        services = snap.services
        selected = snap.selected.flatMap { id in services.contains { $0.id == id } ? id : nil } ?? services.first?.id
        doNotDisturb = snap.doNotDisturb
        dockBadge = snap.dockBadge
        for s in services {
            let c = ServiceController(service: s)
            c.delegate = self
            controllers[s.id] = c
        }
    }

    /// The selected service first, the rest a moment later so launch stays quick.
    func startAll() {
        if let id = selected { controllers[id]?.start() }
        var delay = 0.3
        for s in services where s.id != selected && s.enabled {
            let id = s.id
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.controllers[id]?.start() }
            delay += 0.25
        }
        updateBadge()
    }

    var current: Service? { selected.flatMap(service) }
    var currentController: ServiceController? { selected.flatMap { controllers[$0] } }

    func service(_ id: UUID) -> Service? { services.first { $0.id == id } }

    // MARK: - edits

    @discardableResult
    func add(recipe: Recipe, name: String, url: String?) -> Service {
        var s = Service(recipe: recipe, name: name, url: url)
        s.notifications = true
        services.append(s)
        let c = ServiceController(service: s)
        c.delegate = self
        controllers[s.id] = c
        selected = s.id
        c.start()
        Notifier.shared.askIfNeeded()
        changed()
        return s
    }

    func remove(_ id: UUID) {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return }
        controllers.removeValue(forKey: id)?.destroy()
        Icons.shared.forget(service: id)
        services.remove(at: index)
        if selected == id {
            selected = services.indices.contains(index) ? services[index].id : services.last?.id
            if let id = selected { controllers[id]?.start() }
        }
        changed()
    }

    func edit(_ id: UUID, _ change: (inout Service) -> Void) {
        guard let i = services.firstIndex(where: { $0.id == id }) else { return }
        var s = services[i]
        change(&s)
        guard s != services[i] else { return }
        if !s.enabled { s.unread = 0 }
        services[i] = s
        controllers[id]?.update(s)
        changed()
    }

    func setEnabled(_ id: UUID, _ on: Bool) { edit(id) { $0.enabled = on } }

    func select(_ id: UUID) {
        guard service(id) != nil, selected != id else { return }
        selected = id
        changed()
    }

    func select(index: Int) {
        guard services.indices.contains(index) else { return }
        select(services[index].id)
    }

    func selectNext(_ step: Int) {
        guard !services.isEmpty else { return }
        let i = services.firstIndex { $0.id == selected } ?? 0
        let n = services.count
        select(services[((i + step) % n + n) % n].id)
    }

    func move(_ id: UUID, to index: Int) {
        guard let from = services.firstIndex(where: { $0.id == id }) else { return }
        let s = services.remove(at: from)
        services.insert(s, at: max(0, min(index, services.count)))
        changed()
    }

    func setDoNotDisturb(_ on: Bool) {
        doNotDisturb = on
        changed()
    }

    func setDockBadge(_ on: Bool) {
        dockBadge = on
        changed()
    }

    // MARK: - from the pages

    func serviceDidChange(_ controller: ServiceController) {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func service(_ controller: ServiceController, unread: Int) {
        guard let i = services.firstIndex(where: { $0.id == controller.id }), services[i].unread != unread else { return }
        services[i].unread = unread
        changed()
    }

    func service(_ controller: ServiceController, notify title: String, body: String, noteID: String) {
        guard let s = service(controller.id), s.enabled, s.notifications, !doNotDisturb else { return }
        Notifier.shared.post(service: s, title: title.isEmpty ? s.name : title, body: body, noteID: noteID,
                             icon: Icons.shared.image(for: s))
    }

    /// A banner was clicked.
    func open(service id: UUID, note: String?) {
        guard service(id) != nil else { return }
        (NSApp.delegate as? AppDelegate)?.showWindow()
        select(id)
        if let note, !note.isEmpty { controllers[id]?.clickNotification(note) }
    }

    // MARK: -

    var totalUnread: Int {
        services.filter { $0.enabled && $0.showBadge }.reduce(0) { $0 + $1.unread }
    }

    private func changed() {
        updateBadge()
        NotificationCenter.default.post(name: Self.changed, object: nil)
        saveSoon()
    }

    private func updateBadge() {
        let n = dockBadge ? totalUnread : 0
        NSApp.dockTile.badgeLabel = n > 0 ? (n > 999 ? "999+" : "\(n)") : nil
    }

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func save() {
        saveWork?.cancel()
        var snap = Snapshot()
        snap.services = services
        snap.selected = selected
        snap.doNotDisturb = doNotDisturb
        snap.dockBadge = dockBadge
        Store.save(snap)
    }
}
