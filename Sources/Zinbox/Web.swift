import AppKit
import AVFoundation
import WebKit

// WebKit setup shared by every service, plus the small native pieces pages
// need: downloads, camera and microphone prompts, and JS dialogs.

@MainActor
enum Web {
    static let world = WKContentWorld.world(name: "Zinbox")

    /// Safari's user agent. Some sites refuse WKWebView's default one.
    static let userAgent: String = {
        var version = "18.0"
        for path in ["/Applications/Safari.app", "/System/Cryptexes/App/System/Applications/Safari.app"] {
            if let v = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                version = v
                break
            }
        }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    static func prepare(_ config: WKWebViewConfiguration) {
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = true
        // Hidden services keep running at full speed so they still count and notify.
        config.preferences.inactiveSchedulingPolicy = .none
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(
            WKUserScript(source: Scripts.noPasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        )
    }

    /// WebKit has no public switch for a page's sound; use the private one when
    /// it is there, and do nothing otherwise.
    static func setMuted(_ view: WKWebView, _ muted: Bool) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard view.responds(to: selector), let method = class_getInstanceMethod(type(of: view), selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        let imp = method_getImplementation(method)
        // _WKMediaMutedState: 1 = audio muted.
        unsafeBitCast(imp, to: Setter.self)(view, selector, muted ? 1 : 0)
    }
}

// MARK: - Downloads

@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()
    private var active: [ObjectIdentifier: (WKDownload, URL?)] = [:]

    func track(_ download: WKDownload) {
        download.delegate = self
        active[ObjectIdentifier(download)] = (download, nil)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        destination(for: suggestedFilename) { target in
            self.active[key] = (download, target)
            completionHandler(target)
        }
    }

    /// A free file name in the Downloads folder. Either engine.
    func destination(for suggestedName: String, done: @escaping (URL) -> Void) {
        let folder = Self.folder
        let name = suggestedName.isEmpty ? "download" : suggestedName.replacingOccurrences(of: "/", with: "-")
        // The first touch of ~/Downloads can wait on macOS's privacy prompt;
        // keep that wait off the main thread so the window stays responsive.
        DispatchQueue.global(qos: .userInitiated).async {
            let target = Self.free(name, in: folder)
            DispatchQueue.main.async { done(target) }
        }
    }

    private static var folder: URL {
        if Store.testing { // keeps tests away from the real Downloads folder
            let url = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = active.removeValue(forKey: ObjectIdentifier(download))?.1 {
            // Bounces the Downloads stack in the Dock, as Safari does.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        active.removeValue(forKey: ObjectIdentifier(download))
        let alert = Dialogs.alert(title: "Download failed", message: error.localizedDescription, buttons: ["OK"])
        Dialogs.run(alert, in: NSApp.mainWindow) { _ in }
    }

    nonisolated private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

// MARK: - Camera and microphone

@MainActor
enum Permissions {
    /// Answers given this session, per service host and device.
    private static var answers: [String: Bool] = [:]

    static func ask(origin: String, type: WKMediaCaptureType, service: String, window: NSWindow?,
                    decision: @escaping (WKPermissionDecision) -> Void) {
        ask(origin: origin, video: type != .microphone, audio: type != .camera, screen: false,
            service: service, window: window) { decision($0 ? .grant : .deny) }
    }

    static func ask(origin: String, video: Bool, audio: Bool, screen: Bool, service: String, window: NSWindow?,
                    decision: @escaping (Bool) -> Void) {
        var parts: [String] = []
        if video { parts.append("camera") }
        if audio { parts.append("microphone") }
        if screen { parts.append("screen") }
        let what = parts.isEmpty ? "camera and microphone" : parts.joined(separator: " and ")
        let key = "\(service)|\(origin)|\(what)"
        if let known = answers[key] {
            decision(known)
            return
        }
        let alert = Dialogs.alert(title: "Allow \(service) to use your \(what)?",
                                  message: "\(origin.isEmpty ? "This page" : origin) wants to use your \(what).",
                                  buttons: ["Allow", "Don't Allow"])
        Dialogs.run(alert, in: window) { response in
            let granted = response == .alertFirstButtonReturn
            answers[key] = granted
            guard granted else { return decision(false) }
            // Make sure macOS has asked too, then answer the page. (Screen
            // recording permission is asked by macOS itself when sharing starts.)
            let media: [AVMediaType] = (video ? [.video] : []) + (audio ? [.audio] : [])
            requestSystem(media) { ok in decision(ok) }
        }
    }

    private static func requestSystem(_ media: [AVMediaType], done: @escaping (Bool) -> Void) {
        guard let first = media.first else { return done(true) }
        AVCaptureDevice.requestAccess(for: first) { ok in
            DispatchQueue.main.async {
                guard ok else { return done(false) }
                requestSystem(Array(media.dropFirst()), done: done)
            }
        }
    }
}

// MARK: - Dialogs

@MainActor
enum Dialogs {
    static func alert(title: String, message: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title.isEmpty ? "This page says" : title
        alert.informativeText = message
        for b in buttons { alert.addButton(withTitle: b) }
        return alert
    }

    static func run(_ alert: NSAlert, in window: NSWindow?, done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}
