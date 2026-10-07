import Foundation

// Everything Zinbox remembers lives in one JSON file:
// ~/Library/Application Support/Zinbox/services.json
//
// A run with ZINBOX_PROBE set uses "Zinbox (<name>)" instead, so tests never
// touch the real services or logins.

/// The browser engine a service runs in.
enum Engine: String, Codable {
    /// The system's WebKit: light and efficient.
    case webkit
    /// Embedded Chromium: for sites tuned for Chrome, such as Teams.
    case chromium
}

struct Service: Codable, Identifiable, Equatable {
    var id: UUID
    var recipe: String
    var name: String
    /// Only for the custom recipe, or to override a recipe's start page.
    var url: String?
    /// The WKWebsiteDataStore identifier. One login per service.
    var storeID: UUID
    var enabled = true
    var notifications = true
    var showBadge = true
    var audioMuted = false
    var zoom: Double = 1
    var unread = 0
    /// Nil: the recipe's default engine.
    var engine: Engine?

    init(recipe: Recipe, name: String, url: String?) {
        id = UUID()
        self.recipe = recipe.id
        self.name = name
        self.url = url
        storeID = UUID()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        recipe = try c.decode(String.self, forKey: .recipe)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        storeID = try c.decode(UUID.self, forKey: .storeID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        showBadge = try c.decodeIfPresent(Bool.self, forKey: .showBadge) ?? true
        audioMuted = try c.decodeIfPresent(Bool.self, forKey: .audioMuted) ?? false
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine)
    }

    var effectiveEngine: Engine { engine ?? Recipes.named(recipe)?.engine ?? .webkit }

    var startURL: URL? {
        if let url, let parsed = Service.parse(url) { return parsed }
        return Recipes.named(recipe)?.url
    }

    /// Accepts "slack.com", "https://x.y/z" and similar. Nil for junk.
    static func parse(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") {
            let host = s.split(separator: "/").first.map(String.init)?.split(separator: ":").first.map(String.init) ?? ""
            let local = host == "localhost" || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." }
            s = (local ? "http://" : "https://") + s
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host(), host.contains(".") || host == "localhost"
        else { return nil }
        return url
    }
}

struct Snapshot: Codable {
    var services: [Service] = []
    var selected: UUID?
    var doNotDisturb = false
    var dockBadge = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        services = try c.decodeIfPresent([Service].self, forKey: .services) ?? []
        selected = try c.decodeIfPresent(UUID.self, forKey: .selected)
        doNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? false
        dockBadge = try c.decodeIfPresent(Bool.self, forKey: .dockBadge) ?? true
    }
}

enum Store {
    static let probe: String? = {
        guard let raw = ProcessInfo.processInfo.environment["ZINBOX_PROBE"] else { return nil }
        let clean = raw.lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return clean.isEmpty || clean == "1" ? "test" : clean
    }()

    static var testing: Bool { probe != nil }

    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = probe.map { "Zinbox (\($0))" } ?? "Zinbox"
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var file: URL { folder.appendingPathComponent("services.json") }

    static func load() -> Snapshot {
        guard let data = try? Data(contentsOf: file) else { return Snapshot() }
        if let snap = try? JSONDecoder().decode(Snapshot.self, from: data) { return snap }
        // Keep an unreadable file aside instead of overwriting it.
        let aside = folder.appendingPathComponent("services.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        return Snapshot()
    }

    static func save(_ snap: Snapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snap) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
