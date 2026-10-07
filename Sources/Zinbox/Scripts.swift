import Foundation

// Scripts injected into every service page.
//
// The page world gets a stand-in for the Web Notification API (WKWebView in a
// third-party app has none). It never touches window.webkit, because some
// sites treat that as an embedded browser. It hands notifications to our own
// isolated world through a DOM event, and only that world can talk to native.

enum Scripts {
    static let handler = "zinbox"

    static func unread(_ body: String) -> String {
        """
        (function () {
          if (window.__zinboxCount) return;
          window.__zinboxCount = true;
          var last = -1;
          function fromTitle() {
            var m = (document.title || '').match(/[(\\[](\\d[\\d.,]*)\\+?[)\\]]/);
            return m ? parseInt(m[1].replace(/[.,]/g, ''), 10) || 0 : 0;
          }
          function read() {
            try {
              var v = Math.floor(Number((function () { \(body.isEmpty ? "return 0;" : body) })()) || 0);
              if (v > 0) return v;
            } catch (e) {}
            return fromTitle();
          }
          function tick() {
            var n = Math.max(0, read());
            if (n !== last) {
              last = n;
              try { webkit.messageHandlers.\(handler).postMessage({ type: 'count', count: n }); } catch (e) {}
            }
          }
          tick();
          setInterval(tick, 1500);
        })();
        """
    }

    /// Isolated world, every frame: page notifications become native messages.
    static let bridge = """
    (function () {
      if (window.__zinboxBridge) return;
      window.__zinboxBridge = true;
      document.addEventListener('zinbox-notify', function (e) {
        try {
          var d = e.detail || {};
          webkit.messageHandlers.\(handler).postMessage({
            type: 'notify', id: String(d.id || ''), title: String(d.title || ''),
            body: String(d.body || ''), tag: String(d.tag || ''), icon: String(d.icon || '')
          });
        } catch (err) {}
      }, true);
    })();
    """

    /// Page world, every frame, at document start.
    static let notifications = """
    (function () {
      if (window.__zinboxNotify) return;
      window.__zinboxNotify = true;
      var notes = {};
      var seq = 0;
      function post(n) {
        try {
          document.dispatchEvent(new CustomEvent('zinbox-notify', { detail: {
            id: n.__id, title: n.title, body: n.body, tag: n.tag, icon: n.icon
          }}));
        } catch (e) {}
      }
      function Notify(title, options) {
        if (!(this instanceof Notify)) throw new TypeError("Failed to construct 'Notification'");
        options = options || {};
        this.title = String(title == null ? '' : title);
        this.body = String(options.body || '');
        this.tag = String(options.tag || '');
        this.icon = String(options.icon || '');
        this.data = options.data;
        this.silent = !!options.silent;
        this.onclick = null; this.onshow = null; this.onclose = null; this.onerror = null;
        this.__listeners = {};
        this.__id = 'n' + (++seq) + '-' + Date.now();
        notes[this.__id] = this;
        var keys = Object.keys(notes);
        if (keys.length > 200) delete notes[keys[0]];
        var self = this;
        post(this);
        setTimeout(function () { self.__fire('show'); }, 0);
      }
      Notify.prototype.addEventListener = function (type, fn) {
        (this.__listeners[type] = this.__listeners[type] || []).push(fn);
      };
      Notify.prototype.removeEventListener = function (type, fn) {
        var l = this.__listeners[type] || [];
        var i = l.indexOf(fn);
        if (i >= 0) l.splice(i, 1);
      };
      Notify.prototype.dispatchEvent = function () { return true; };
      Notify.prototype.__fire = function (type) {
        var ev = { type: type, target: this, currentTarget: this, preventDefault: function () {} };
        try { if (typeof this['on' + type] === 'function') this['on' + type](ev); } catch (e) {}
        (this.__listeners[type] || []).slice().forEach(function (fn) { try { fn(ev); } catch (e) {} });
      };
      Notify.prototype.close = function () { delete notes[this.__id]; this.__fire('close'); };
      Object.defineProperty(Notify, 'permission', { get: function () { return 'granted'; } });
      Object.defineProperty(Notify, 'maxActions', { get: function () { return 0; } });
      Notify.requestPermission = function (cb) {
        if (typeof cb === 'function') { try { cb('granted'); } catch (e) {} }
        return Promise.resolve('granted');
      };
      try {
        Object.defineProperty(window, 'Notification', { value: Notify, writable: true, configurable: true });
      } catch (e) { window.Notification = Notify; }

      // Sites that notify through their service worker.
      if (window.ServiceWorkerRegistration) {
        ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
          new Notify(title, options);
          return Promise.resolve();
        };
        ServiceWorkerRegistration.prototype.getNotifications = function () { return Promise.resolve([]); };
      }

      // Permission queries some sites make before notifying.
      try {
        if (navigator.permissions && navigator.permissions.query) {
          var query = navigator.permissions.query.bind(navigator.permissions);
          navigator.permissions.query = function (desc) {
            if (desc && (desc.name === 'notifications' || desc.name === 'push')) {
              return Promise.resolve({ state: 'granted', status: 'granted', onchange: null,
                addEventListener: function () {}, removeEventListener: function () {} });
            }
            return query(desc);
          };
        }
      } catch (e) {}

      window.__zinboxClick = function (id) {
        var n = notes[id];
        try { window.focus(); } catch (e) {}
        if (n) n.__fire('click');
      };
    })();
    """

    /// Isolated world: the page's declared icons, best first.
    static let icons = """
    (function () {
      var out = [];
      document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"], link[rel="shortcut icon"]').forEach(function (l) {
        if (!l.href) return;
        var size = 0;
        (l.getAttribute('sizes') || '').split(/\\s+/).forEach(function (s) {
          var m = s.match(/^(\\d+)x/); if (m) size = Math.max(size, parseInt(m[1], 10));
        });
        if (!size && /apple-touch/.test(l.rel)) size = 180;
        if (!size && /\\.svg(\\?|$)/i.test(l.href)) size = 256;
        if (!size) size = 32;
        out.push({ href: l.href, size: size });
      });
      out.sort(function (a, b) { return b.size - a.size; });
      return out.map(function (o) { return o.href; }).slice(0, 6);
    })();
    """

    /// WKWebView cannot finish Google's phone/Bluetooth passkey flow, which
    /// strands the user on "make sure Bluetooth is on". Report WebAuthn as
    /// unavailable so sites fall back to a password.
    static let noPasskeys = """
    (function () {
      try {
        Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true, writable: true });
      } catch (e) {}
      try {
        if (window.CredentialsContainer) {
          var proto = CredentialsContainer.prototype;
          ['get', 'create'].forEach(function (name) {
            var real = proto[name];
            proto[name] = function (options) {
              if (options && options.publicKey) {
                return Promise.reject(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'));
              }
              return real.apply(this, arguments);
            };
          });
        }
      } catch (e) {}
    })();
    """

    static func click(_ id: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [id])) ?? Data("[\"\"]".utf8)
        let arg = String(decoding: data, as: UTF8.self)
        return "window.__zinboxClick && window.__zinboxClick(\(arg)[0]);"
    }
}
