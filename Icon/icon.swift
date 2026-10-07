// App icon: three stacked chat bubbles — many inboxes, one window — in white
// on black, full-bleed (macOS masks it to the app-icon shape). Drawn, not exported.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// A rounded speech bubble with a short tail at the bottom left.
func bubble(_ r: NSRect, radius: CGFloat, tail: CGFloat) -> [NSBezierPath] {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    let t = NSBezierPath()
    let x = r.minX + radius * 0.55
    t.move(to: NSPoint(x: x - tail * 0.2, y: r.minY + tail))
    t.line(to: NSPoint(x: x + tail * 1.1, y: r.minY + tail * 0.4))
    t.curve(to: NSPoint(x: x - tail * 0.55, y: r.minY - tail * 0.7),
            controlPoint1: NSPoint(x: x + tail * 0.5, y: r.minY - tail * 0.3),
            controlPoint2: NSPoint(x: x, y: r.minY - tail * 0.6))
    t.curve(to: NSPoint(x: x - tail * 0.2, y: r.minY + tail),
            controlPoint1: NSPoint(x: x - tail * 0.25, y: r.minY - tail * 0.35),
            controlPoint2: NSPoint(x: x - tail * 0.2, y: r.minY))
    t.close()
    return [p, t]
}

func draw(_ size: CGFloat, background: Bool = true) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        // Full-bleed artwork: macOS applies the rounded app-icon mask itself.
        // (Drawing our own rounded plate makes macOS 26+ shrink the icon onto
        // a grey backing plate.) The motif uses an 824-point design grid
        // scaled up to the full canvas.
        let s = size / 824
        let plate = NSRect(x: 0, y: 0, width: size, height: size)
        if background {
            NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.04, alpha: 1)])?
                .draw(in: plate, angle: -90)
        }

        // Two bubbles behind, then the front one.
        let w: CGFloat = 430 * s, h: CGFloat = 320 * s, radius: CGFloat = 112 * s
        let step = NSPoint(x: 62 * s, y: 70 * s)
        let front = NSRect(x: plate.midX - w / 2 - step.x, y: plate.midY - h / 2 - step.y - 10 * s, width: w, height: h)
        for (i, white) in [(2, 0.30), (1, 0.55)] {
            let r = front.offsetBy(dx: step.x * CGFloat(i), dy: step.y * CGFloat(i))
            NSColor(white: white, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }
        // A gap around the front bubble, painted with the plate, so the stack
        // reads as separate layers.
        let gap = bubble(front.insetBy(dx: -16 * s, dy: -16 * s), radius: radius + 16 * s, tail: 70 * s)
        for part in gap {
            NSGraphicsContext.saveGraphicsState()
            part.addClip()
            if background {
                NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.04, alpha: 1)])?
                    .draw(in: plate, angle: -90)
            } else {
                NSGraphicsContext.current?.compositingOperation = .clear
                plate.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.white.setFill()
        bubble(front, radius: radius, tail: 58 * s).forEach { $0.fill() }

        // Three dots: typing.
        NSColor(white: 0.06, alpha: 1).setFill()
        let dot: CGFloat = 46 * s
        for i in -1...1 {
            let c = NSPoint(x: front.midX + CGFloat(i) * 92 * s, y: front.midY)
            NSBezierPath(ovalIn: NSRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot)).fill()
        }
        return true
    }
}

func write(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

// `icon.swift <iconset dir> [glyph.png]`: the iconset for older macOS, and
// optionally the bubbles alone on transparency, the foreground layer of the
// Icon Composer icon that macOS 26+ uses.
if CommandLine.arguments.count > 2 {
    write(draw(1024, background: false), to: URL(fileURLWithPath: CommandLine.arguments[2]), pixels: 1024)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(draw(CGFloat(pixels)), to: out.appendingPathComponent(name), pixels: pixels)
    }
}
print("drew: \(out.path)")
