import AppKit
import ZinboxCEF

// Services on the Chromium engine. Chromium starts the first time one is
// needed; until then Zinbox carries no Chromium processes at all.

@MainActor
enum Chromium {
    static var root: URL { Store.folder.appendingPathComponent("Chromium", isDirectory: true) }

    /// False when this build has no Chromium (e.g. `swift run`); WebKit is used instead.
    static func start() -> Bool {
        ZBChromium.start(withCacheRoot: root.path)
    }

    /// The same scripts WebKit services get. Chromium has no separate script
    /// world, so they share the page's, and post through a native function
    /// instead of webkit.messageHandlers.
    ///
    /// Chromium adds secure-context interfaces (Notification, PublicKeyCredential)
    /// after it creates the context, over anything set before. So the shims are
    /// installed again later, but still before any of the page's own scripts.
    static let pageScript = """
    (function () {
      function install() {
        delete window.__zinboxNotify;
        \(Scripts.noPasskeys)
        \(wrap(Scripts.notifications))
      }
      install();
      Promise.resolve().then(install);
      // And once the parser inserts the first element, before the first script.
      try {
        new MutationObserver(function (m, o) { o.disconnect(); install(); })
          .observe(document, { childList: true, subtree: true });
      } catch (e) {}
    })();
    \(wrap(Scripts.bridge))
    """

    static func mainScript(_ unread: String) -> String { wrap(Scripts.unread(unread)) + "\n" + wrap(passwordFocus) }

    /// Reports whether a password field has focus, so Zinbox can keep macOS
    /// Secure Input off the rest of the time (see SecureInput).
    private static let passwordFocus = """
    (function () {
      var last = null;
      function report() {
        var el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        var on = !!(el && el.tagName === 'INPUT' && String(el.type).toLowerCase() === 'password');
        if (on === last) return;
        last = on;
        try { webkit.messageHandlers.\(Scripts.handler).postMessage({ type: 'secure', on: on }); } catch (e) {}
      }
      document.addEventListener('focusin', report, true);
      document.addEventListener('focusout', function () { setTimeout(report, 0); }, true);
      document.addEventListener('DOMContentLoaded', report);
      window.addEventListener('pagehide', function () { last = null; report(); });
      report();
    })();
    """

    private static func wrap(_ source: String) -> String {
        """
        (function (webkit) {
        \(source)
        })({ messageHandlers: { \(Scripts.handler): { postMessage: function (m) {
          try { __zinboxNative(JSON.stringify(m)); } catch (e) {}
        } } } });
        """
    }
}

extension ServiceController: @preconcurrency ZBChromiumDelegate {
    func chromiumDidChangeLoading(_ view: ZBChromiumView, loading: Bool) {
        setLoading(loading)
    }

    func chromium(_ view: ZBChromiumView, progress: Double) {
        pane.progress = progress
    }

    func chromium(_ view: ZBChromiumView, titleChanged title: String) {}

    func chromiumDidFinishLoad(_ view: ZBChromiumView) {
        clearFailure()
        SecureInput.reconcile()
    }

    func chromium(_ view: ZBChromiumView, loadFailed message: String) {
        showFailure(message)
    }

    func chromium(_ view: ZBChromiumView, message json: String) {
        guard let data = json.data(using: .utf8), let body = try? JSONSerialization.jsonObject(with: data) else { return }
        handle(body)
    }

    func chromium(_ view: ZBChromiumView, shouldOpenInApp url: URL, newWindow: Bool) -> Bool {
        newWindow ? Self.isSignIn(url) : belongs(url)
    }

    func chromium(_ view: ZBChromiumView, openExternally url: URL) {
        openOutside(url)
    }

    func chromiumRendererCrashed(_ view: ZBChromiumView) {
        pageCrashed()
    }

    func chromium(_ view: ZBChromiumView, faviconURLs urls: [URL]) {
        Icons.shared.learn(service: id, from: urls, userAgent: Web.userAgent)
    }

    func chromium(_ view: ZBChromiumView, wantsMedia origin: String, video: Bool, audio: Bool, screen: Bool,
                  decision: @escaping (Bool) -> Void) {
        Permissions.ask(origin: origin, video: video, audio: audio, screen: screen, service: service.name,
                        window: view.window, decision: decision)
    }

    func chromium(_ view: ZBChromiumView, download suggestedName: String, destination: @escaping (URL?) -> Void) {
        Downloads.shared.destination(for: suggestedName) { destination($0) }
    }
}
