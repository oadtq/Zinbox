#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass Chromium requires (CefAppProtocol). Zinbox runs on it
/// whether or not any service uses Chromium.
@interface ZBApplication : NSApplication
@end

@class ZBChromiumView;

/// Callbacks from one Chromium page, always on the main thread.
@protocol ZBChromiumDelegate <NSObject>
- (void)chromiumDidChangeLoading:(ZBChromiumView *)view loading:(BOOL)loading;
- (void)chromium:(ZBChromiumView *)view progress:(double)progress;
- (void)chromium:(ZBChromiumView *)view titleChanged:(NSString *)title;
- (void)chromiumDidFinishLoad:(ZBChromiumView *)view;
- (void)chromium:(ZBChromiumView *)view loadFailed:(NSString *)message;
/// A message from the injected scripts: {"type":"count"|"notify", ...}.
- (void)chromium:(ZBChromiumView *)view message:(NSString *)json;
/// A main-frame link the user followed, or a new window. YES keeps it in the app.
- (BOOL)chromium:(ZBChromiumView *)view shouldOpenInApp:(NSURL *)url newWindow:(BOOL)newWindow;
- (void)chromium:(ZBChromiumView *)view openExternally:(NSURL *)url;
- (void)chromiumRendererCrashed:(ZBChromiumView *)view;
- (void)chromium:(ZBChromiumView *)view faviconURLs:(NSArray<NSURL *> *)urls;
- (void)chromium:(ZBChromiumView *)view wantsMedia:(NSString *)origin video:(BOOL)video audio:(BOOL)audio
          screen:(BOOL)screen decision:(void (^)(BOOL allowed))decision;
- (void)chromium:(ZBChromiumView *)view download:(NSString *)suggestedName
     destination:(void (^)(NSURL *_Nullable destination))destination;
@end

@interface ZBChromium : NSObject
/// Starts Chromium on first use. Returns NO if it can't (the framework or
/// helpers are missing); services then fall back to WebKit.
+ (BOOL)startWithCacheRoot:(NSString *)root;
+ (BOOL)isRunning;
/// Closes every page, shuts Chromium down, then calls `done`.
+ (void)shutdown:(void (^)(void))done;
/// Deletes a profile's data. Call when no page is using it.
+ (void)removeProfile:(NSString *)profile;
@end

/// One Chromium page, embedded as a child view.
@interface ZBChromiumView : NSView
@property (nonatomic, weak, nullable) id<ZBChromiumDelegate> delegate;
@property (nonatomic, readonly, nullable) NSURL *URL;

/// `profile` is a folder name under the cache root: one login per profile.
/// `pageScript` runs in every frame before the page's own scripts;
/// `mainFrameScript` runs in the main frame only.
- (instancetype)initWithProfile:(NSString *)profile
                            url:(NSURL *)url
                     pageScript:(NSString *)pageScript
                mainFrameScript:(NSString *)mainFrameScript;

- (void)loadURL:(NSURL *)url;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)goBack;
- (void)goForward;
- (void)setZoom:(double)factor;
- (void)setAudioMuted:(BOOL)muted;
- (void)evaluateJavaScript:(NSString *)script;
- (void)showDevTools;
- (void)focusPage;
/// Releases the page. The view is unusable afterwards.
- (void)close;
@end

NS_ASSUME_NONNULL_END
