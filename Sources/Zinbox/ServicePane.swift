import AppKit
import WebKit

// What fills the window below the tab bar for one service: the page, a thin
// progress line while it loads, or a message when it is disabled or failed.

@MainActor
final class ServicePane: NSView {
    enum State: Equatable {
        case page
        case disabled(String)
        case failed(String)
    }

    var retry: (() -> Void)?
    var enable: (() -> Void)?

    private weak var webView: NSView?
    private let bar = ProgressLine()
    private var overlay: NSView?
    private var state: State = .page

    var loading = false {
        didSet { bar.setVisible(loading && state == .page) }
    }

    var progress: Double = 0 {
        didSet { bar.progress = progress }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.content.cgColor
        bar.autoresizingMask = [.width, .minYMargin]
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView?.frame = bounds
        overlay?.frame = bounds
        bar.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.content.cgColor
    }

    func host(_ view: NSView) {
        webView?.removeFromSuperview()
        webView = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: bar)
    }

    func show(_ new: State) {
        guard new != state || (overlay == nil && new != .page) else { return }
        state = new
        overlay?.removeFromSuperview()
        overlay = nil
        webView?.isHidden = new != .page
        bar.setVisible(loading && new == .page)
        switch new {
        case .page:
            return
        case .disabled(let name):
            overlay = message(symbol: "moon.zzz", title: "\(name) is disabled",
                              detail: "Disabled services are not loaded and send no notifications. Your login is kept.",
                              button: "Enable", action: #selector(enableTapped))
        case .failed(let error):
            overlay = message(symbol: "wifi.exclamationmark", title: "This service couldn't be loaded",
                              detail: error, button: "Try Again", action: #selector(retryTapped))
        }
        if let overlay {
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
        }
    }

    @objc private func retryTapped() { retry?() }
    @objc private func enableTapped() { enable?() }

    private func message(symbol: String, title: String, detail: String, button: String, action: Selector) -> NSView {
        let box = NSView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .light))
        icon.contentTintColor = .tertiaryLabelColor

        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 17, weight: .semibold)
        head.alignment = .center

        let body = NSTextField(wrappingLabelWithString: detail)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 380

        let go = NSButton(title: button, target: self, action: action)
        go.bezelStyle = .push
        go.controlSize = .large
        go.keyEquivalent = "\r"

        let stack = NSStackView(views: [icon, head, body, go])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
        return box
    }
}

/// Two-point accent line along the top edge.
@MainActor
final class ProgressLine: NSView {
    private let fill = CALayer()

    var progress: Double = 0 {
        didSet { layoutFill(animated: true) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutFill(animated: false)
    }

    override func updateLayer() {
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setVisible(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.1 : 0.35
            animator().alphaValue = on ? 1 : 0
        }
    }

    private func layoutFill(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0.08, min(1, progress))), height: bounds.height)
        CATransaction.commit()
    }
}
