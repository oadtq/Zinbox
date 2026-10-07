import AppKit
import WebKit

// One service: its web view, its delegates, and the view that holds it.
//
// The web view lives as long as the service is enabled, whether or not it is
// on screen, so background services keep counting and notifying. Disabling a
// service releases the web view; its data store (the login) stays on disk.

@MainActor
protocol ServiceControllerDelegate: AnyObject {
    func serviceDidChange(_ controller: ServiceController)
    func service(_ controller: ServiceController, unread: Int)
    func service(_ controller: ServiceController, notify title: String, body: String, noteID: String)
}

@MainActor
final class ServiceController: NSObject {
    let id: UUID
    private(set) var service: Service
    weak var delegate: ServiceControllerDelegate?

    let pane = ServicePane()
    private(set) var webView: WKWebView?
    private(set) var isLoading = false
    private(set) var failure: String?
    private var popups: [PopupWindow] = []
    private var crashes: [Date] = []
    private var observations: [NSKeyValueObservation] = []
    private var iconTried = false

    init(service: Service) {
        id = service.id
        self.service = service
        super.init()
        pane.retry = { [weak self] in self?.reload() }
        pane.enable = { [weak self] in
            guard let self else { return }
            AppModel.shared.setEnabled(self.id, true)
        }
        refreshPane()
    }

    var recipe: Recipe { Recipes.named(service.recipe) ?? Recipes.custom }

    func update(_ new: Service) {
        let old = service
        service = new
        if old.audioMuted != new.audioMuted { applyMute() }
        if old.zoom != new.zoom { webView?.pageZoom = new.zoom }
        if new.enabled && !old.enabled { start() }
        if !new.enabled && old.enabled { stop() }
        if new.enabled, old.url != new.url, webView != nil { goHome() }
        refreshPane()
    }

    // MARK: - lifecycle

    func start() {
        guard service.enabled, webView == nil else { return }
        let view = makeWebView()
        webView = view
        pane.host(view)
        applyMute()
        goHome()
        refreshPane()
    }

    func stop() {
        for popup in popups { popup.close() }
        popups.removeAll()
        guard let view = webView else { return }
        observations.removeAll()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.removeFromSuperview()
        webView = nil
        isLoading = false
        failure = nil
        refreshPane()
        delegate?.serviceDidChange(self)
    }

    func goHome() {
        guard let view = webView, let url = service.startURL else { return }
        failure = nil
        view.load(URLRequest(url: url))
    }

    func reload() {
        guard let view = webView else { start(); return }
        failure = nil
        if view.url == nil || view.url?.absoluteString == "about:blank" {
            goHome()
        } else {
            view.reload()
        }
        refreshPane()
    }

    /// Removing a service: drop the view and its data store.
    func destroy() {
        stop()
        WKWebsiteDataStore.remove(forIdentifier: service.storeID) { _ in }
    }

    func clickNotification(_ noteID: String) {
        webView?.evaluateJavaScript(Scripts.click(noteID), in: nil, in: .page, completionHandler: nil)
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: service.storeID)
        Web.prepare(config)

        let content = config.userContentController
        content.add(WeakHandler(self), contentWorld: Web.world, name: Scripts.handler)
        content.addUserScript(WKUserScript(source: Scripts.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world))
        content.addUserScript(WKUserScript(source: Scripts.notifications, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        content.addUserScript(WKUserScript(source: Scripts.unread(recipe.unread), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = false
        view.isInspectable = true
        view.pageZoom = service.zoom
        view.customUserAgent = Web.userAgent
        observations = [
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.loadingChanged(view.isLoading) }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.pane.progress = view.estimatedProgress }
            },
        ]
        return view
    }

    private func loadingChanged(_ loading: Bool) {
        isLoading = loading
        pane.loading = loading
        delegate?.serviceDidChange(self)
    }

    private func applyMute() {
        guard let view = webView else { return }
        Web.setMuted(view, service.audioMuted)
    }

    private func refreshPane() {
        if !service.enabled {
            pane.show(.disabled(service.name))
        } else if let failure {
            pane.show(.failed(failure))
        } else {
            pane.show(.page)
        }
    }

    // MARK: - icon

    private func fetchIcon() {
        guard let view = webView, !iconTried else { return }
        iconTried = true
        view.evaluateJavaScript(Scripts.icons, in: nil, in: Web.world) { [weak self] result in
            guard let self else { return }
            var candidates: [URL] = []
            if case .success(let value) = result, let list = value as? [String] {
                candidates = list.compactMap(URL.init(string:))
            }
            if let page = view.url, let origin = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL {
                candidates.append(origin)
            }
            Icons.shared.learn(service: self.id, from: candidates, userAgent: Web.userAgent)
        }
    }

    // MARK: - links

    /// Hosts that keep a link inside the service, beyond the recipe's own.
    private static let signIn = [
        "accounts.google.com", "accounts.youtube.com", "login.microsoftonline.com", "login.live.com",
        "login.microsoft.com", "account.live.com", "appleid.apple.com", "okta.com", "auth0.com",
        "onelogin.com", "duosecurity.com", "facebook.com", "slack.com",
    ]

    func belongs(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        var hosts = recipe.hosts + Self.signIn
        if let start = service.startURL?.host()?.lowercased() {
            hosts.append(start)
            let parts = start.split(separator: ".")
            if parts.count >= 2 { hosts.append(parts.suffix(2).joined(separator: ".")) }
        }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    fileprivate func openOutside(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    fileprivate func popupClosed(_ popup: PopupWindow) {
        popups.removeAll { $0 === popup }
    }

    fileprivate func handle(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "count":
            let n = (dict["count"] as? NSNumber)?.intValue ?? 0
            delegate?.service(self, unread: max(0, n))
        case "notify":
            let title = (dict["title"] as? String) ?? ""
            let text = (dict["body"] as? String) ?? ""
            let note = (dict["id"] as? String) ?? ""
            delegate?.service(self, notify: title, body: text, noteID: note)
        default:
            break
        }
    }
}

// MARK: - WKScriptMessageHandler

/// The content controller retains its handlers; this keeps it from retaining us.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ServiceController?
    init(_ owner: ServiceController) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.handle(body) }
    }
}

// MARK: - WKNavigationDelegate

extension ServiceController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow, preferences)
            return
        }
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            // mailto:, tel:, zoommtg:, msteams: and friends.
            openOutside(url)
            decisionHandler(.cancel, preferences)
            return
        }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let clicked = action.navigationType == .linkActivated
        if mainFrame, clicked, ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) || !belongs(url) {
            openOutside(url)
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType || !response.isForMainFrame ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if failure != nil {
            failure = nil
            refreshPane()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failure = nil
        refreshPane()
        fetchIcon()
        delegate?.serviceDidChange(self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        let ns = error as NSError
        // Cancelled loads, and loads we turned into downloads or handed out.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && [102, 204].contains(ns.code) { return }
        failure = ns.localizedDescription
        refreshPane()
        delegate?.serviceDidChange(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashes.count > 3 {
            failure = "This page stopped working several times in a row."
            refreshPane()
            return
        }
        let wait = Double(crashes.count) * 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView else { return }
            webView.reload()
        }
    }
}

// MARK: - WKUIDelegate

extension ServiceController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        if let url, !url.absoluteString.isEmpty, scheme != "about" {
            if !["http", "https", "blob", "data"].contains(scheme) {
                openOutside(url)
                return nil
            }
            // An ordinary link with target=_blank: open it in the browser.
            if !belongs(url) || action.modifierFlags.contains(.command) {
                openOutside(url)
                return nil
            }
        }
        // A sign-in window, or a blank window the page fills in: keep it here,
        // in this service's login.
        let popup = PopupWindow(configuration: configuration, owner: self, features: windowFeatures, parent: webView.window)
        popups.append(popup)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === self.webView { reload() }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        Permissions.ask(origin: origin.host, type: type, service: service.name, window: webView.window, decision: decisionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = Dialogs.alert(title: frame.securityOrigin.host, message: message, buttons: ["OK"])
        Dialogs.run(alert, in: webView.window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = Dialogs.alert(title: frame.securityOrigin.host, message: message, buttons: ["OK", "Cancel"])
        Dialogs.run(alert, in: webView.window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = Dialogs.alert(title: frame.securityOrigin.host, message: prompt, buttons: ["OK", "Cancel"])
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        Dialogs.run(alert, in: webView.window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
}

// MARK: - Popup windows

/// A window the page opened: usually a sign-in. Shares the service's login.
@MainActor
final class PopupWindow: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private weak var owner: ServiceController?
    private var observation: NSKeyValueObservation?
    private var shown = false

    init(configuration: WKWebViewConfiguration, owner: ServiceController, features: WKWindowFeatures, parent: NSWindow?) {
        self.owner = owner
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Web.userAgent
        webView.isInspectable = true
        let width = features.width.map { CGFloat(truncating: $0) } ?? 520
        let height = features.height.map { CGFloat(truncating: $0) } ?? 680
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(380, width), height: max(420, height)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.title = owner.service.name
        window.contentView = webView
        window.delegate = self
        webView.uiDelegate = self
        webView.navigationDelegate = self
        if let parent {
            let p = parent.frame
            window.setFrameOrigin(NSPoint(x: p.midX - window.frame.width / 2, y: p.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        observation = webView.observe(\.title) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, let title = view.title, !title.isEmpty else { return }
                self.window.title = title
            }
        }
        // Show once something loads, so a popup that is immediately handed to
        // the browser never flashes on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.show() }
    }

    private func show() {
        guard !shown, window.delegate != nil else { return }
        shown = true
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.delegate = nil
        webView.stopLoading()
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        window.orderOut(nil)
        owner?.popupClosed(self)
    }

    func windowWillClose(_ notification: Notification) { close() }

    func webViewDidClose(_ webView: WKWebView) {
        window.close()
        close()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url, let owner else {
            decisionHandler(.allow, preferences)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let fresh = webView.url == nil || webView.url?.absoluteString == "about:blank"
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if mainFrame, ["http", "https"].contains(scheme), fresh, !owner.belongs(url) {
            // window.open('') then location = link: really an outside link.
            owner.openOutside(url)
            decisionHandler(.cancel, preferences)
            close()
            return
        }
        if !["http", "https", "about", "blob", "data"].contains(scheme) {
            owner.openOutside(url)
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { show() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
