// Chromium (CEF) inside Zinbox: startup, the message pump, and one embedded
// browser per ZBChromiumView. CEF's UI thread is the main thread here, so
// every handler below runs on it and can call straight into AppKit.

#import "ZinboxCEF.h"

#include <cmath>
#include <set>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_library_loader.h"

// MARK: - NSApplication

@interface ZBApplication () <CefAppProtocol>
@end

@implementation ZBApplication {
    BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)value { _handlingSendEvent = value; }

- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent scoped;
    [super sendEvent:event];
}
@end

// MARK: - Message pump
//
// CEF asks for work through OnScheduleMessagePumpWork; we run it from the main
// run loop. Between requests a slow heartbeat keeps it ticking in case a
// request is missed. (CEF's sample uses 30 Hz; that costs ~2% CPU at idle.)

namespace {

constexpr double kHeartbeat = 0.25;

NSTimer *gTimer = nil;
bool gInWork = false;
bool gReentered = false;
bool gRunning = false;
bool gShuttingDown = false;
NSString *gRoot = nil;
std::set<int> gBrowsers;  // every open browser, popups included
void (^gShutdownDone)(void) = nil;

void schedule(double seconds);

/// Runs `block` on the main run loop in every mode. GCD's main queue would stall
/// while AppKit waits in a modal mode, e.g. when quitting.
void onMain(void (^block)(void)) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void doWork() {
    if (gInWork) {
        gReentered = true;
        return;
    }
    gInWork = true;
    CefDoMessageLoopWork();
    gInWork = false;
    if (gReentered) {
        gReentered = false;
        schedule(0);
    } else if (!gTimer && gRunning) {
        schedule(kHeartbeat);
    }
}

void schedule(double seconds) {
    [gTimer invalidate];
    gTimer = nil;
    if (!gRunning) return;
    if (seconds <= 0) {
        onMain(^{ doWork(); });
        return;
    }
    gTimer = [NSTimer timerWithTimeInterval:MIN(seconds, kHeartbeat) repeats:NO block:^(NSTimer *) {
        gTimer = nil;
        doWork();
    }];
    // Keep pumping during menus, resizes and other tracking loops.
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

void finishShutdownIfIdle() {
    if (!gShuttingDown || !gBrowsers.empty()) return;
    if (gInWork) {  // inside CefDoMessageLoopWork: try again once it returns
        onMain(^{ finishShutdownIfIdle(); });
        return;
    }
    gShuttingDown = false;
    // Let CEF finish closing before tearing it down.
    for (int i = 0; i < 10; i++) CefDoMessageLoopWork();
    gRunning = false;
    [gTimer invalidate];
    gTimer = nil;
    CefShutdown();
    if (gShutdownDone) {
        auto done = gShutdownDone;
        gShutdownDone = nil;
        done();
    }
}

class BrowserApp : public CefApp, public CefBrowserProcessHandler {
   public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    void OnBeforeCommandLineProcessing(const CefString &process_type, CefRefPtr<CefCommandLine> line) override {
        if (!process_type.empty()) return;
        // Services in hidden tabs keep running so they still count and notify.
        line->AppendSwitch("disable-background-timer-throttling");
        line->AppendSwitch("disable-renderer-backgrounding");
        line->AppendSwitch("disable-backgrounding-occluded-windows");
        // Ringtones and notification sounds play without a click first.
        line->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");
        // Don't ask for a Keychain password on every launch of an ad-hoc build.
        line->AppendSwitch("use-mock-keychain");
    }

    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        onMain(^{ schedule(delay_ms / 1000.0); });
    }

   private:
    IMPLEMENT_REFCOUNTING(BrowserApp);
};

NSString *str(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }
NSURL *url(const CefString &s) { return [NSURL URLWithString:str(s)]; }

bool isWebScheme(NSURL *u) {
    NSString *scheme = u.scheme.lowercaseString ?: @"";
    return [@[ @"http", @"https", @"about", @"data", @"blob", @"devtools", @"chrome", @"chrome-error" ] containsObject:scheme];
}

}  // namespace

// MARK: - Client

@interface ZBChromiumView ()
- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)browserClosed;
@end

namespace {

class Client : public CefClient,
               public CefLifeSpanHandler,
               public CefDisplayHandler,
               public CefLoadHandler,
               public CefRequestHandler,
               public CefKeyboardHandler,
               public CefDownloadHandler,
               public CefPermissionHandler {
   public:
    explicit Client(ZBChromiumView *view) : view_(view) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

    id<ZBChromiumDelegate> delegate() { return view_.delegate; }

    // Life span

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        gBrowsers.insert(browser->GetIdentifier());
        if (!browser->IsPopup()) [view_ attachBrowser:browser];
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        // Sign-in popups live in their own CEF window: let it close as usual.
        if (browser->IsPopup()) return false;
        // An embedded page: the default would send performClose: to Zinbox's main
        // window. Detaching the page's view completes the close instead.
        NSView *page = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
        [page removeFromSuperview];
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        gBrowsers.erase(browser->GetIdentifier());
        popupsUnsettled_.erase(browser->GetIdentifier());
        if (!browser->IsPopup()) [view_ browserClosed];
        // Never shut CEF down from inside one of its own callbacks.
        onMain(^{ finishShutdownIfIdle(); });
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                       const CefString &target_url, const CefString &target_frame_name,
                       WindowOpenDisposition target_disposition, bool user_gesture,
                       const CefPopupFeatures &popupFeatures, CefWindowInfo &windowInfo,
                       CefRefPtr<CefClient> &client, CefBrowserSettings &settings,
                       CefRefPtr<CefDictionaryValue> &extra_info, bool *no_javascript_access) override {
        NSURL *u = url(target_url);
        NSString *s = u.absoluteString ?: @"";
        if (s.length == 0 || [s isEqualToString:@"about:blank"]) {
            // A blank window the page fills in next; decided on its first navigation.
            nextPopupUnsettled_ = true;
            return false;
        }
        if (isWebScheme(u) && [delegate() chromium:view_ shouldOpenInApp:u newWindow:YES]) return false;
        [delegate() chromium:view_ openExternally:u];
        return true;
    }

    void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override { nextPopupUnsettled_ = false; }

    // Navigation

    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                        bool user_gesture, bool is_redirect) override {
        if (!frame->IsMain()) return false;
        NSURL *u = url(request->GetURL());
        if (!u) return false;
        if (!isWebScheme(u)) {  // mailto:, msteams:, zoommtg: …
            [delegate() chromium:view_ openExternally:u];
            return true;
        }
        NSString *scheme = u.scheme.lowercaseString;
        bool web = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
        if (browser->IsPopup()) {
            int id = browser->GetIdentifier();
            if (nextPopupUnsettled_) {
                nextPopupUnsettled_ = false;
                popupsUnsettled_.insert(id);
            }
            if (popupsUnsettled_.count(id) && web) {
                popupsUnsettled_.erase(id);
                if (![delegate() chromium:view_ shouldOpenInApp:u newWindow:YES]) {
                    [delegate() chromium:view_ openExternally:u];
                    browser->GetHost()->CloseBrowser(true);
                    return true;
                }
            }
            return false;
        }
        auto transition = request->GetTransitionType();
        bool link = (transition & TT_SOURCE_MASK) == TT_LINK;
        if (web && user_gesture && !is_redirect && link && ![delegate() chromium:view_ shouldOpenInApp:u newWindow:NO]) {
            [delegate() chromium:view_ openExternally:u];
            return true;
        }
        return false;
    }

    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &target_url,
                          WindowOpenDisposition target_disposition, bool user_gesture) override {
        // ⌘-click and middle-click: always the browser.
        if (NSURL *u = url(target_url)) [delegate() chromium:view_ openExternally:u];
        return true;
    }

    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int error_code,
                                   const CefString &error_string) override {
        if (!browser->IsPopup()) [delegate() chromiumRendererCrashed:view_];
    }

    // Display and load

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
        if (!browser->IsPopup()) return (void)[delegate() chromium:view_ titleChanged:str(title)];
        // Sign-in windows: show the page title in the window's title bar.
        NSView *page = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
        page.window.title = str(title);
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString> &icon_urls) override {
        if (browser->IsPopup()) return;
        NSMutableArray<NSURL *> *list = [NSMutableArray array];
        for (const auto &u : icon_urls)
            if (NSURL *x = url(u)) [list addObject:x];
        [delegate() chromium:view_ faviconURLs:list];
    }

    void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
        if (!browser->IsPopup()) [delegate() chromium:view_ progress:progress];
    }

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack,
                              bool canGoForward) override {
        if (browser->IsPopup()) return;
        [delegate() chromiumDidChangeLoading:view_ loading:isLoading];
        if (!isLoading) [delegate() chromiumDidFinishLoad:view_];
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode,
                     const CefString &errorText, const CefString &failedUrl) override {
        if (browser->IsPopup() || !frame->IsMain() || errorCode == ERR_ABORTED) return;
        NSString *text = str(errorText);
        [delegate() chromium:view_ loadFailed:text.length ? text : @"The page couldn't be loaded."];
    }

    // Messages from the injected scripts (via the helper's renderer process).

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  CefProcessId source_process, CefRefPtr<CefProcessMessage> message) override {
        if (message->GetName() != "zinbox" || browser->IsPopup()) return false;
        [delegate() chromium:view_ message:str(message->GetArgumentList()->GetString(0))];
        return true;
    }

    // Keyboard: ⌘-shortcuts go to the menu bar first, as in any Mac browser.

    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event,
                       bool *is_keyboard_shortcut) override {
        NSEvent *e = (__bridge NSEvent *)os_event;
        // Modifier-only presses arrive here too (as flagsChanged); they have no characters.
        if (!e || e.type != NSEventTypeKeyDown || event.type != KEYEVENT_RAWKEYDOWN ||
            !(e.modifierFlags & NSEventModifierFlagCommand))
            return false;
        // Leave editing commands to the page's own text handling.
        NSString *key = e.charactersIgnoringModifiers.lowercaseString;
        NSEventModifierFlags mods = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if (mods == NSEventModifierFlagCommand && [@[ @"c", @"v", @"x", @"a", @"z" ] containsObject:key]) return false;
        return [[NSApp mainMenu] performKeyEquivalent:e];
    }

    // Downloads

    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                          const CefString &suggested_name, CefRefPtr<CefBeforeDownloadCallback> callback) override {
        CefRefPtr<CefBeforeDownloadCallback> keep = callback;
        [delegate() chromium:view_ download:str(suggested_name) destination:^(NSURL *dest) {
            if (dest) keep->Continue(dest.path.UTF8String, false);
        }];
        return true;
    }

    // Camera, microphone and screen sharing

    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                        const CefString &origin, uint32_t requested,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        BOOL audio = (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0;
        BOOL video = (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0;
        BOOL screen = (requested & (CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) != 0;
        CefRefPtr<CefMediaAccessCallback> keep = callback;
        [delegate() chromium:view_ wantsMedia:str(origin) video:video audio:audio screen:screen decision:^(BOOL allowed) {
            keep->Continue(allowed ? requested : CEF_MEDIA_PERMISSION_NONE);
        }];
        return true;
    }

   private:
    __weak ZBChromiumView *view_;
    bool nextPopupUnsettled_ = false;
    std::set<int> popupsUnsettled_;
    IMPLEMENT_REFCOUNTING(Client);
};

}  // namespace

// MARK: - ZBChromium

@implementation ZBChromium

+ (BOOL)startWithCacheRoot:(NSString *)root {
    if (gRunning) return YES;
    static CefScopedLibraryLoader *loader = nullptr;
    static bool failed = false;
    if (failed) return NO;
    NSString *helper = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Contents/Frameworks/Zinbox Helper.app/Contents/MacOS/Zinbox Helper"];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:helper]) {
        failed = true;
        return NO;
    }
    loader = new CefScopedLibraryLoader();
    if (!loader->LoadInMain()) {
        failed = true;
        return NO;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    gRoot = root;

    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    static char **argv = nullptr;
    argv = (char **)calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = strdup(args[i].UTF8String);
    CefMainArgs main_args((int)args.count, argv);

    CefSettings settings;
    settings.external_message_pump = true;
    settings.multi_threaded_message_loop = false;
    settings.persist_session_cookies = true;
    settings.log_severity = LOGSEVERITY_ERROR;
    settings.background_color = CefColorSetARGB(255, 255, 255, 255);
    CefString(&settings.root_cache_path) = root.UTF8String;
    CefString(&settings.cache_path) = [root stringByAppendingPathComponent:@"Default"].UTF8String;
    CefString(&settings.browser_subprocess_path) = helper.UTF8String;
    CefString(&settings.log_file) = [root stringByAppendingPathComponent:@"chromium.log"].UTF8String;

    gRunning = true;  // the pump must accept work CefInitialize schedules
    if (!CefInitialize(main_args, settings, new BrowserApp(), nullptr)) {
        gRunning = false;
        failed = true;
        return NO;
    }
    schedule(0);
    return YES;
}

+ (BOOL)isRunning { return gRunning; }

+ (void)shutdown:(void (^)(void))done {
    if (!gRunning) {
        done();
        return;
    }
    gShutdownDone = [done copy];
    gShuttingDown = true;
    for (NSWindow *w in NSApp.windows) {
        for (ZBChromiumView *v in [self viewsIn:w.contentView]) [v close];
    }
    finishShutdownIfIdle();
    // Don't let a stuck page hold up quitting.
    NSTimer *fallback = [NSTimer timerWithTimeInterval:3 repeats:NO block:^(NSTimer *) {
        if (gShutdownDone) {
            gBrowsers.clear();
            finishShutdownIfIdle();
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:fallback forMode:NSRunLoopCommonModes];
}

+ (NSArray<ZBChromiumView *> *)viewsIn:(NSView *)root {
    if (!root) return @[];
    NSMutableArray *out = [NSMutableArray array];
    if ([root isKindOfClass:ZBChromiumView.class]) [out addObject:root];
    for (NSView *sub in root.subviews) [out addObjectsFromArray:[self viewsIn:sub]];
    return out;
}

+ (void)removeProfile:(NSString *)profile {
    if (!gRoot || profile.length == 0 || [profile containsString:@"/"]) return;
    [NSFileManager.defaultManager removeItemAtPath:[gRoot stringByAppendingPathComponent:profile] error:nil];
}

@end

// MARK: - ZBChromiumView

@implementation ZBChromiumView {
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<Client> _client;
    double _zoom;
    BOOL _muted;
    BOOL _closed;
}

- (instancetype)initWithProfile:(NSString *)profile url:(NSURL *)url pageScript:(NSString *)pageScript
                mainFrameScript:(NSString *)mainFrameScript {
    self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)];
    if (!self) return nil;
    _zoom = 1;
    self.autoresizesSubviews = YES;
    _client = new Client(self);

    CefRequestContextSettings context;
    CefString(&context.cache_path) = [gRoot stringByAppendingPathComponent:profile].UTF8String;
    context.persist_session_cookies = true;

    CefRefPtr<CefDictionaryValue> extra = CefDictionaryValue::Create();
    extra->SetString("page", pageScript.UTF8String);
    extra->SetString("main", mainFrameScript.UTF8String);

    CefWindowInfo info;
    info.SetAsChild((__bridge CefWindowHandle)self, CefRect(0, 0, 800, 600));
    CefBrowserSettings settings;
    CefBrowserHost::CreateBrowser(info, _client, url.absoluteString.UTF8String, settings, extra,
                                  CefRequestContext::CreateContext(context, nullptr));
    return self;
}

- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser {
    _browser = browser;
    if (_closed) {  // closed while it was still being created
        browser->GetHost()->CloseBrowser(true);
        return;
    }
    NSView *page = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    page.frame = self.bounds;
    page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (_zoom != 1) [self setZoom:_zoom];
    if (_muted) browser->GetHost()->SetAudioMuted(true);
}

- (void)browserClosed {
    _browser = nullptr;
}

- (void)layout {
    [super layout];
    for (NSView *sub in self.subviews) sub.frame = self.bounds;
}

- (NSURL *)URL {
    if (!_browser) return nil;
    return url(_browser->GetMainFrame()->GetURL());
}

- (void)loadURL:(NSURL *)u {
    if (_browser) _browser->GetMainFrame()->LoadURL(u.absoluteString.UTF8String);
}

- (void)reload {
    if (_browser) _browser->Reload();
}

- (void)reloadIgnoringCache {
    if (_browser) _browser->ReloadIgnoreCache();
}

- (void)goBack {
    if (_browser) _browser->GoBack();
}

- (void)goForward {
    if (_browser) _browser->GoForward();
}

- (void)setZoom:(double)factor {
    _zoom = factor;
    // Chromium's zoom level is a power of 1.2.
    if (_browser) _browser->GetHost()->SetZoomLevel(std::log(factor) / std::log(1.2));
}

- (void)setAudioMuted:(BOOL)muted {
    _muted = muted;
    if (_browser) _browser->GetHost()->SetAudioMuted(muted);
}

- (void)evaluateJavaScript:(NSString *)script {
    if (_browser) _browser->GetMainFrame()->ExecuteJavaScript(script.UTF8String, "", 0);
}

- (void)showDevTools {
    if (!_browser) return;
    CefWindowInfo info;
    CefBrowserSettings settings;
    _browser->GetHost()->ShowDevTools(info, nullptr, settings, CefPoint());
}

- (void)focusPage {
    if (!_browser) return;
    NSView *page = (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
    if (page.window) [page.window makeFirstResponder:page];
    _browser->GetHost()->SetFocus(true);
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    if (!_browser) return;  // still being created: attachBrowser closes it
    _browser->GetHost()->CloseBrowser(true);
    // Detaching the page's view finishes the close even while AppKit is
    // waiting on us (e.g. quitting), when the close request alone can stall.
    [(__bridge NSView *)_browser->GetHost()->GetWindowHandle() removeFromSuperview];
}

@end
