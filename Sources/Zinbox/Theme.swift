import AppKit

// Colours as light/dark pairs that follow the system appearance.

enum Theme {
    static let bar = pair(light: 0xECECEC, dark: 0x1E1E1E)
    static let content = pair(light: 0xFFFFFF, dark: 0x161616)
    static let separator = pair(light: 0xD4D4D4, dark: 0x2E2E2E)
    static let tabSelected = NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 1, alpha: 1)
    }
    static let tabHover = NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05)
    }
    static let tabSelectedEdge = NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.08)
    }
    static let badge = NSColor(srgbRed: 0.93, green: 0.23, blue: 0.23, alpha: 1)

    static let barHeight: CGFloat = 40

    private static func pair(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { a in rgb(a.isDark ? dark : light) }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
