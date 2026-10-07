import AppKit

// Service icons: the site's own icon, fetched from the site and kept on disk,
// or a lettered plate in the brand colour until there is one.

@MainActor
final class Icons {
    static let shared = Icons()
    static let changed = Notification.Name("ZinboxIconsChanged")

    private var memory: [String: NSImage] = [:]
    private var fetching: Set<String> = []
    private let folder: URL = {
        let url = Store.folder.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func image(for service: Service) -> NSImage {
        // Known services keep their brand icon; a sign-in page's favicon is not it.
        if let recipe = Recipes.named(service.recipe), !recipe.isCustom, let shared = cached("recipe-\(recipe.id)") {
            return shared
        }
        if let own = cached("service-\(service.id.uuidString)") { return own }
        let tint = Recipes.named(service.recipe)?.tint ?? Recipes.custom.tint
        return plate(service.name, tint: tint)
    }

    func image(for recipe: Recipe) -> NSImage {
        if recipe.isCustom {
            return symbolPlate("globe", tint: recipe.tint)
        }
        if let img = cached("recipe-\(recipe.id)") { return img }
        fetchRecipe(recipe)
        return plate(recipe.name, tint: recipe.tint)
    }

    /// Fetch every catalogue icon once, so new tabs show the real icon at once.
    func warm() {
        for recipe in Recipes.all where cached("recipe-\(recipe.id)") == nil { fetchRecipe(recipe) }
    }

    /// Candidates come from the loaded page, best first.
    func learn(service id: UUID, from candidates: [URL], userAgent: String) {
        let key = "service-\(id.uuidString)"
        fetch(key, candidates: candidates, userAgent: userAgent)
    }

    func forget(service id: UUID) {
        let key = "service-\(id.uuidString)"
        memory[key] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(key + ".png"))
    }

    private func fetchRecipe(_ recipe: Recipe) {
        guard let base = URL(string: "/", relativeTo: recipe.url)?.absoluteURL else { return }
        let candidates = ["apple-touch-icon.png", "favicon.ico"].compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        fetch("recipe-\(recipe.id)", candidates: candidates, userAgent: Web.userAgent)
    }

    private func cached(_ key: String) -> NSImage? {
        if let img = memory[key] { return img }
        let file = folder.appendingPathComponent(key + ".png")
        guard let img = NSImage(contentsOf: file) else { return nil }
        memory[key] = img
        return img
    }

    private func fetch(_ key: String, candidates: [URL], userAgent: String) {
        guard !fetching.contains(key), !candidates.isEmpty else { return }
        fetching.insert(key)
        let file = folder.appendingPathComponent(key + ".png")
        Task.detached(priority: .utility) {
            var found: Data?
            for url in candidates {
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let png = Icons.normalise(data)
                else { continue }
                found = png
                break
            }
            let result = found
            await MainActor.run {
                self.fetching.remove(key)
                guard let found = result, let img = NSImage(data: found) else { return }
                try? found.write(to: file, options: .atomic)
                self.memory[key] = img
                NotificationCenter.default.post(name: Icons.changed, object: nil)
            }
        }
    }

    /// Any image format in, a 64×64 PNG out. Nil if it is not an image or is too small.
    nonisolated static func normalise(_ data: Data) -> Data? {
        guard let source = NSImage(data: data), source.isValid else { return nil }
        let reps = source.representations
        let biggest = reps.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        // SVGs and PDFs report 0 pixels; anything tiny looks bad scaled up.
        guard biggest == 0 || biggest >= 16 else { return nil }
        let side = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func plate(_ name: String, tint: NSColor) -> NSImage {
        let letter = String(name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased()
        let key = "plate-\(letter)-\(tint.description)"
        if let img = memory[key] { return img }
        let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            tint.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            return true
        }
        memory[key] = img
        return img
    }

    private func symbolPlate(_ symbol: String, tint: NSColor) -> NSImage {
        let key = "symbol-\(symbol)"
        if let img = memory[key] { return img }
        let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            tint.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        memory[key] = img
        return img
    }
}
