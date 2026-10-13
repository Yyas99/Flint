// Flint: a native macOS browser. The window, tabs, sidebar and settings are AppKit; pages are rendered
// by WebKit (Safari's engine). Ad blocking is compiled into WebKit content rules, and Chrome-style
// extensions (Proton Pass…) run on Flint's own extension layer (FExt below).
// Build: see the `flint` script.

#import <sys/xattr.h>
#import <sys/resource.h>
#import <mach/mach_time.h>
#import <libproc.h>
#import <sys/sysctl.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <sqlite3.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <libkern/OSByteOrder.h>

#pragma mark - Engine: WebKit (Safari's engine), with Flint's own blocking and extension system

#import <WebKit/WebKit.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

static void FlintReloadBlocklists(void);
static void FlintSetBlocking(BOOL on);
static void CtlOut(NSString *s);
static void RelayoutAll(void);
static void FlintInternalInstall(WKWebViewConfiguration *c, WKUserContentController *ucc);
static NSString *ThemeCSS(void);
static void FlintCosmeticInstall(WKUserContentController *ucc);
// Quit and reopen (extension changes take effect at launch); tabs are restored.
static void FlintRelaunch(void) {
    [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:@[@"-c", [NSString stringWithFormat:@"sleep 1.2; open \"%@\"", NSBundle.mainBundle.bundlePath]]];
    [NSApp terminate:nil];
}

#pragma mark - Settings keys

static NSString *const kSearch        = @"searchEngine";     // index into Engines()
static NSString *const kStartup       = @"startup";          // 0 restore tabs, 1 new tab
static NSString *const kBlock         = @"blockAds";
static NSString *const kStrip         = @"stripTracking";
static NSString *const kCookieReject  = @"rejectCookieBanners";
static NSString *const kAutoPiP       = @"autoPictureInPicture";   // a playing video floats when you leave its tab   // say no to cookie banners automatically
static NSString *const kSleepMins     = @"sleepMinutes";
static NSString *const kShowBookmarks = @"showBookmarks";
static NSString *const kSidebarHidden = @"sidebarHidden";
static NSString *const kSidebarW      = @"sidebarWidth";
static NSString *const kTabsState     = @"tabs";
static NSString *const kAllowlist     = @"blockAllowlist";
static NSString *const kListsUpdated  = @"listsUpdated";
static NSString *const kListsOn       = @"filterLists";
static NSString *const kZoom          = @"zoomByHost";
static NSString *const kScripts       = @"javascript";
static NSString *const kDefaultZoom   = @"defaultZoom";
static NSString *const kDownloadDir   = @"downloadFolder";
static NSString *const kAskDownload   = @"askWhereToSave";
static NSString *const kTheme         = @"theme";            // 0 follow macOS, 1 graphite, 2 carbon, 3 light
static NSString *const kAccent        = @"accent";           // index into Accents()
static NSString *const kDensity       = @"density";          // 0 compact, 1 comfortable, 2 roomy
static NSString *const kSidebarRight  = @"sidebarRight";
static NSString *const kHideButtons   = @"hiddenToolbarButtons";
static NSString *const kHTTPSOnly     = @"httpsOnly";
static NSString *const kGPC           = @"globalPrivacyControl";
static NSString *const kClearOnQuit   = @"clearDataOnQuit";
static NSString *const kSitePerms     = @"sitePermissions";   // host → {camera, microphone: 1 allow / 2 block}
static NSString *const kJSOff         = @"javascriptOffSites";
static NSString *const kCustomEngine  = @"customSearchEngine"; // [name, url with %@]
static NSString *const kDLAccel        = @"downloadAccelerator";   // Flint's multi-connection downloader for http(s) files
static NSString *const kCodec          = @"videoCodec";          // 0 automatic, 1 avoid AV1, 2 H.264 only
static NSString *const kCodec30       = @"videoMax30fps";
static NSString *const kBgThrottle    = @"backgroundThrottle";   // 0 standard, 1 save power on battery, 2 always
static NSString *const kSingleProcess = @"singleWebProcess";
static NSString *const kRestorePaused = @"restoredVideoPaused";
static NSString *const kResumeMedia = @"resumeVideoPosition";
static NSString *const kProfiles = @"profiles";              // [{id, name}]: profiles besides the first one
static NSString *const kMainProfileName = @"mainProfileName"; // what the first profile is called (default "Personal")
static NSString *const kMainProfileColor = @"mainProfileColor"; // its colour (index into ProfileColors)
static NSString *const kLazyRestore   = @"loadOpenTabOnClick";
static NSString *const kUserAgent     = @"userAgent";         // 0 Safari, 1 Chrome, 2 Firefox
static NSString *const kConfirmQuit   = @"confirmQuit";
static NSString *const kMinFont       = @"minimumFontSize";
static NSString *const kExtDisabled    = @"disabledExtensions";
static NSString *const kHomeTopSites  = @"homeTopSites";
static NSString *const kSuggestNet    = @"searchSuggestions";

static NSUserDefaults *Defaults(void) { return NSUserDefaults.standardUserDefaults; }

// Toolbar customisation. Core buttons are on unless hidden; extras (home, reader…) are off unless added.
static NSString *const kShowExtra     = @"shownToolbarButtons";
static NSString *const kAddrWidth     = @"addressBarWidth";      // 0 full, 1 medium, 2 compact
static NSString *const kExtPinned     = @"pinnedExtensions";     // ids; missing = everything pinned
static NSArray<NSString *> *OptInButtons(void) { return @[@"home", @"newtab", @"reader", @"share", @"dlalways"]; }
static BOOL ToolbarShows(NSString *key) {
    if ([OptInButtons() containsObject:key]) return [[Defaults() arrayForKey:kShowExtra] containsObject:key];
    return ![[Defaults() arrayForKey:@"hiddenToolbarButtons"] containsObject:key];
}
static void SetToolbarShows(NSString *key, BOOL on) {
    BOOL opt = [OptInButtons() containsObject:key];
    NSString *store = opt ? kShowExtra : @"hiddenToolbarButtons";
    NSMutableArray *a = [[Defaults() arrayForKey:store] ?: @[] mutableCopy];
    [a removeObject:key];
    if (opt == on) [a addObject:key];
    [Defaults() setObject:a forKey:store];
}
static BOOL ExtensionPinned(NSString *ident) {
    NSArray *p = [Defaults() arrayForKey:kExtPinned];
    return !p || [p containsObject:ident];
}

// Debug log next to the source when it exists (~/Documents/Flint/flint.log).
// Developer files live beside Flint.app (in Documents); they're touched only on this background queue,
// so a macOS folder-access prompt can never freeze the browser itself.
static dispatch_queue_t DevQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("flint.dev", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static void DLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate.date descriptionWithLocale:nil], s];
    dispatch_async(DevQueue(), ^{
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Flint/flint.log"];
        if (![NSFileManager.defaultManager fileExistsAtPath:path.stringByDeletingLastPathComponent]) return;
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) { [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
        [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
    });
}

#pragma mark - Look

static NSColor *Hex(uint32_t h) {
    return [NSColor colorWithSRGBRed:((h >> 16) & 255) / 255.0 green:((h >> 8) & 255) / 255.0 blue:(h & 255) / 255.0 alpha:1];
}
static NSColor *HexA(uint32_t h, CGFloat a) { return [Hex(h) colorWithAlphaComponent:a]; }

// Themes: Graphite (dark grey), Carbon (near black, like the icon), Light, or follow macOS.
// Accents never include yellow.
static NSColor *vBg, *vPill, *vPillFocus, *vHover, *vActive, *vLine, *vText, *vDim, *vFaint, *vAccent, *vContentBg;
static NSColor *vCard, *vNav, *vPanel, *vToast, *vLinkBg, *vSep, *vBorder, *vCloseHover, *vBadgeText;
static NSColor *vEmber;   // the one highlight colour: your accent, or a quiet grey with Silver
static NSArray<NSArray *> *Accents(void) {
    return @[@[@"Silver", @0xdcdce2, @0x2c2c30], @[@"Crimson", @0xff3b55, @0xd70f35], @[@"Ember", @0xff6a3d, @0xe0461c],
             @[@"Blue", @0x5aa2ff, @0x1f6fe0], @[@"Violet", @0xb08cff, @0x7b4ee0], @[@"Green", @0x4fd18b, @0x14995a], @[@"Pink", @0xff7ab8, @0xe0408a]];
}
static BOOL ThemeIsLight(void) {
    NSInteger t = [Defaults() integerForKey:kTheme];
    if (t == 3) return YES;
    if (t != 0) return NO;
    NSAppearanceName n = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [n isEqualToString:NSAppearanceNameAqua];
}
static NSAppearance *ThemeAppearance(void) { return [NSAppearance appearanceNamed:ThemeIsLight() ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua]; }
static void InitPalette(void) {
    NSInteger t = [Defaults() integerForKey:kTheme];
    BOOL light = ThemeIsLight(), carbon = (t == 2);
    if (light) {
        vBg = Hex(0xe9e9ec); vPill = Hex(0xffffff); vPillFocus = Hex(0xffffff); vHover = Hex(0xdcdce1);
        vActive = Hex(0xd2d2d8); vLine = Hex(0xc4c4cb); vText = Hex(0x1b1b1e); vDim = Hex(0x55555c);
        vFaint = Hex(0x8b8b92); vContentBg = Hex(0xffffff);
        vCard = Hex(0xffffff); vNav = Hex(0xe2e2e6); vPanel = Hex(0xeeeef1); vToast = Hex(0x2a2a2e); vLinkBg = HexA(0xffffff, 0.97);
        vSep = HexA(0x000000, 0.07); vBorder = HexA(0x000000, 0.08); vCloseHover = Hex(0xc9c9d0); vBadgeText = Hex(0xffffff);
    } else if (carbon) {
        vBg = Hex(0x0d0d0f); vPill = Hex(0x1a1a1d); vPillFocus = Hex(0x141416); vHover = Hex(0x1c1c20);
        vActive = Hex(0x232327); vLine = Hex(0x2b2b30); vText = Hex(0xededf0); vDim = Hex(0x9d9da4);
        vFaint = Hex(0x66666d); vContentBg = Hex(0x0f0f11);
        vCard = Hex(0x18181b); vNav = Hex(0x0f0f11); vPanel = Hex(0x121214); vToast = Hex(0x232327); vLinkBg = HexA(0x161619, 0.96);
        vSep = HexA(0xffffff, 0.05); vBorder = HexA(0xffffff, 0.05); vCloseHover = Hex(0x34343a); vBadgeText = Hex(0x0d0d0f);
    } else {
        vBg = Hex(0x1c1c1e); vPill = Hex(0x2a2a2d); vPillFocus = Hex(0x232326); vHover = Hex(0x2c2c30);
        vActive = Hex(0x333338); vLine = Hex(0x3a3a3f); vText = Hex(0xececee); vDim = Hex(0xa3a3a9);
        vFaint = Hex(0x6e6e75); vContentBg = Hex(0x1b1b1d);
        vCard = Hex(0x262629); vNav = Hex(0x1a1a1c); vPanel = Hex(0x1f1f22); vToast = Hex(0x2f2f33); vLinkBg = HexA(0x232326, 0.96);
        vSep = HexA(0xffffff, 0.06); vBorder = HexA(0xffffff, 0.06); vCloseHover = Hex(0x45454b); vBadgeText = Hex(0x1c1c1e);
    }
    NSArray *a = Accents()[(NSUInteger)MAX(0, MIN((NSInteger)Accents().count - 1, [Defaults() integerForKey:kAccent]))];
    vAccent = Hex((uint32_t)[a[light ? 2 : 1] unsignedIntValue]);
    vEmber = [Defaults() integerForKey:kAccent] == 0 ? [vText colorWithAlphaComponent:0.55] : vAccent;   // Silver: no colour at all
}

static NSFont *UIFont(CGFloat s, NSFontWeight w) { return [NSFont systemFontOfSize:s weight:w]; }
// Headings: San Francisco at display sizes (the system face, tuned for large text), not a serif:
// crisp and neutral, like the rest of macOS. Very large sizes go a step lighter so they don't shout.
static NSFont *TitleFont(CGFloat s, BOOL bold) {
    return [NSFont systemFontOfSize:s weight:!bold ? NSFontWeightRegular : s >= 36 ? NSFontWeightMedium : NSFontWeightSemibold];
}
static NSImage *Symbol(NSString *name, CGFloat pt, NSFontWeight w) {
    NSImage *im = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!im) return nil;
    return [im imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt weight:w]];
}
static NSImage *Tinted(NSImage *im, NSColor *c) {
    if (!im) return nil;
    return [NSImage imageWithSize:im.size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [im drawInRect:r]; [c set]; NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop); return YES;
    }];
}
// Flint's look: quiet and exact. Soft macOS corners, hairline edges, no glow; colour only where it means something.
static void RoundRect(NSRect r, CGFloat radius, NSColor *fill) {
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
}
static void ShardStroke(NSRect r, CGFloat c, NSColor *color, CGFloat w) {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, w / 2, w / 2) xRadius:c yRadius:c]; p.lineWidth = w; [color setStroke]; [p stroke];
}
static void FacetView(NSView *v, CGFloat c, NSColor *edge) {
    v.wantsLayer = YES;
    CALayer *L = v.layer; L.mask = nil; L.cornerRadius = c; L.masksToBounds = YES;
    if (@available(macOS 11.0, *)) L.cornerCurve = kCACornerCurveContinuous;
    for (CALayer *s in L.sublayers.copy) if ([s.name isEqualToString:@"facetEdge"]) [s removeFromSuperlayer];
    L.borderWidth = edge ? 1 : 0; L.borderColor = edge.CGColor;
}
// Condensed system type for big display text (SF Pro's narrow widths), falling back to regular widths.
static void DrawImage(NSImage *im, NSRect r) {
    [im drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}
// Fill r with the image at its own proportions, centred; the overflow is cropped by the caller's clip (like CSS object-fit: cover).
static void DrawImageFill(NSImage *im, NSRect r) {
    NSSize s = im.size; if (s.width <= 0 || s.height <= 0) return;
    CGFloat k = MAX(NSWidth(r) / s.width, NSHeight(r) / s.height);
    NSRect d = NSMakeRect(NSMidX(r) - s.width * k / 2, NSMidY(r) - s.height * k / 2, s.width * k, s.height * k);
    [im drawInRect:d fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}
static NSRect CenterIn(NSSize s, NSRect r) {
    return NSMakeRect(round(NSMidX(r) - s.width / 2), round(NSMidY(r) - s.height / 2), s.width, s.height);
}
static void Clip(NSView *v) { @try { [v setValue:@YES forKey:@"clipsToBounds"]; } @catch (NSException *e) {} }
static NSString *Trim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

static NSString *HostOf(NSURL *u) {
    NSString *h = u.host.lowercaseString ?: @"";
    return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}
static NSString *SupportDir(void) {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:@"Vela"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
static NSString *SupportFile(NSString *name) { return [SupportDir() stringByAppendingPathComponent:name]; }

#pragma mark - Search engines

static NSArray<NSArray<NSString *> *> *Engines(void) {
    NSArray *base = @[@[@"DuckDuckGo", @"https://duckduckgo.com/?q=%@"],
             @[@"Google", @"https://www.google.com/search?q=%@"],
             @[@"Brave Search", @"https://search.brave.com/search?q=%@"],
             @[@"Kagi", @"https://kagi.com/search?q=%@"],
             @[@"Startpage", @"https://www.startpage.com/do/search?q=%@"],
             @[@"Ecosia", @"https://www.ecosia.org/search?q=%@"],
             @[@"Bing", @"https://www.bing.com/search?q=%@"],
             @[@"Perplexity", @"https://www.perplexity.ai/search?q=%@"]];
    NSArray *c = [Defaults() arrayForKey:kCustomEngine];
    if (c.count == 2 && [c[1] containsString:@"%@"]) base = [base arrayByAddingObject:c];
    return base;
}
static NSArray<NSString *> *Engine(void) {
    NSInteger i = [Defaults() integerForKey:kSearch];
    NSArray *e = Engines();
    return e[(NSUInteger)MAX(0, MIN((NSInteger)e.count - 1, i))];
}
static NSURL *SearchURL(NSString *q) {
    NSString *enc = [q stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    enc = [enc stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
    enc = [enc stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return [NSURL URLWithString:[NSString stringWithFormat:Engine()[1], enc]];
}

// What the address bar does with typed text: a URL if it looks like one, otherwise a search.
static NSURL *URLFromInput(NSString *s) {
    s = Trim(s);
    if (!s.length) return nil;
    if ([s rangeOfString:@" "].location == NSNotFound) {
        NSRegularExpression *scheme = [NSRegularExpression regularExpressionWithPattern:@"^[a-zA-Z][a-zA-Z0-9+.-]*:" options:0 error:nil];
        if ([scheme firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] && ![s hasPrefix:@"localhost:"]) {
            NSURL *u = [NSURL URLWithString:s];
            if (u.scheme && ([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"] || [u.scheme isEqualToString:@"file"] || [u.scheme isEqualToString:@"about"] || [u.scheme isEqualToString:@"flint"] || [u.scheme isEqualToString:@"chrome-extension"] || [u.scheme isEqualToString:@"view-source"])) return u;
        }
        NSRegularExpression *hostish = [NSRegularExpression regularExpressionWithPattern:
            @"^(localhost|[^./\\s]+(\\.[^./\\s]+)*\\.[a-zA-Z]{2,}|\\d{1,3}(\\.\\d{1,3}){3})(:\\d+)?(/.*)?$" options:0 error:nil];
        if ([hostish firstMatchInString:s options:0 range:NSMakeRange(0, s.length)]) {
            NSURL *u = [NSURL URLWithString:[(([s hasPrefix:@"localhost"] || [s rangeOfString:@"127.0.0.1"].location == 0) ? @"http://" : @"https://") stringByAppendingString:s]];
            if (u) return u;
        }
    }
    return SearchURL(s);
}

// Tracking tags that ride along on links (utm_*, fbclid, gclid...). Removed before a page loads.
static NSURL *StripTracking(NSURL *u) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
    if (!c.queryItems.count) return nil;
    static NSRegularExpression *rx;
    if (!rx) rx = [NSRegularExpression regularExpressionWithPattern:
        @"^(utm_[a-z_]+|gclid|gclsrc|dclid|gbraid|wbraid|fbclid|msclkid|mc_cid|mc_eid|igshid|igsh|yclid|_hsenc|_hsmi|ref_src|oly_anon_id|oly_enc_id|vero_id|_openstat|twclid|ttclid|li_fat_id|mkt_tok|srsltid)$"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSMutableArray *keep = [NSMutableArray array]; BOOL hit = NO;
    for (NSURLQueryItem *q in c.queryItems) {
        if ([rx firstMatchInString:q.name options:0 range:NSMakeRange(0, q.name.length)]) hit = YES; else [keep addObject:q];
    }
    if (!hit) return nil;
    c.queryItems = keep.count ? keep : nil;
    return c.URL;
}

#pragma mark - Interfaces

@class VTab, VPage, VWindow, VSidebar, VToolbar, VBookmarksBar, VHome, VFindBar, VSuggest;

// A page rendered by Chromium. One per awake tab.
@interface VPage : NSView
@property (strong, readonly) WKWebView *web;
- (instancetype)initWithFrame:(NSRect)r web:(WKWebView *)given;
@property (weak) VTab *tab;
@property (copy) NSString *url, *title;
@property BOOL loading;
@property double progress;
@property NSInteger blocked;
@property CGFloat zoom;
@property (strong) NSMutableArray<NSString *> *back, *forward;
@property (readonly) BOOL canGoBack, canGoForward;
- (void)open:(NSString *)url record:(BOOL)record;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)close;
- (void)paste:(id)s;
- (void)setZoomLevel:(CGFloat)z;
- (void)find:(NSString *)q forward:(BOOL)fwd next:(BOOL)next;
- (void)stopFind;
- (void)focus;
- (void)download:(NSString *)url;
- (void)source:(void (^)(NSString *))done;
- (void)runJS:(NSString *)code;
- (void)hardReload;
- (void)print;
- (NSArray<NSString *> *)historyForSleep;
- (id)sessionState;
- (void)setMuted:(BOOL)m;
- (void)pictureInPicture;
- (void)checkVideo;
- (void)noteMediaTime;
- (void)resumeMedia;
- (void)restoreState:(id)state url:(NSString *)url;
@end

@interface VTab : NSObject
@property (strong) VPage *web;              // nil while asleep or on the new tab page
@property (copy) NSString *url, *title;
@property (strong) NSImage *favicon;
@property BOOL pinned, loading, isHome, noBlock, audible, muted;
@property BOOL hasVideo, inPiP;          // the page shows a video (the address bar offers picture in picture)
@property double progress;
@property (strong) NSArray *savedBack;     // history kept while asleep
@property (strong) id savedState;          // WebKit's own back/forward + scroll state, kept while asleep and across launches
@property NSTimeInterval hiddenAt;
@property NSTimeInterval lastInput;      // when you last clicked or typed in this tab (the CPU rule leaves it alone for a while)
@property NSInteger blocked;
@property (weak) VWindow *owner;          // the window this tab lives in
@property BOOL deferred;                  // restored at launch, waiting for a click before it loads
@property BOOL launchRestored;            // its first load happens at launch (video starts paused)
@property double mediaTime, savedMedia, resumeAt;   // where the video in this tab was, the last value saved, and a pending seek
@property (copy) NSString *mediaKey;
@property BOOL resuming;               // which video that time belongs to
@property BOOL launchFront;               // the tab on screen at launch: paced like everything else even if it makes sound
@end

@interface VHistory : NSObject
+ (instancetype)shared;                              // the history of the profile you're using
+ (instancetype)forProfile:(NSString *)profile;
+ (void)flushAll;
- (void)visit:(NSURL *)u title:(NSString *)t;
- (NSArray<NSDictionary *> *)match:(NSString *)q limit:(NSUInteger)n;
- (NSArray<NSDictionary *> *)topSites:(NSUInteger)n;
- (NSArray<NSDictionary *> *)recent:(NSUInteger)n;
- (void)clear;
- (NSArray<NSDictionary *> *)all;
- (void)removeURLs:(NSArray<NSString *> *)urls;
- (void)removeHost:(NSString *)host;
- (void)removeSince:(NSTimeInterval)since;
@end

@interface VBookmarks : NSObject
@property (strong) NSMutableArray<NSMutableDictionary *> *bar;   // {name,url} or {name,children:[...]}
+ (instancetype)shared;
- (void)save;
- (NSMutableDictionary *)find:(NSString *)url;
- (void)toggle:(NSString *)url title:(NSString *)title;
- (NSArray<NSDictionary *> *)allURLs;
@end

@interface VFavicons : NSObject
+ (instancetype)shared;
- (NSImage *)iconForURL:(NSString *)url;
- (void)fetchFor:(NSURL *)page href:(NSString *)href done:(void (^)(NSImage *))done;
- (void)remember:(NSImage *)im forURL:(NSString *)url;
@end

@interface VBlocker : NSObject
@property (copy) NSString *status;
+ (instancetype)shared;
- (void)prepare:(void (^)(void))ready;
- (void)updateLists:(BOOL)force done:(void (^)(void))done;
@end

@interface VButton : NSButton <NSDraggingSource>
@property BOOL dragsPage;   // the site button: drag it to put the page on the bookmarks bar (or anywhere that takes links)
@property (copy) NSString *symbolName;
@property CGFloat symbolSize;
@property (nonatomic) BOOL active, hovered;
+ (instancetype)symbol:(NSString *)s size:(CGFloat)pt tip:(NSString *)tip target:(id)t action:(SEL)a;
@end

@interface VWindow : NSWindowController <NSWindowDelegate, NSTextFieldDelegate, NSMenuDelegate>
@property (readonly) BOOL isPrivate;
@property (strong, readonly) WKWebsiteDataStore *privateStore;   // private windows: this window's own, in memory only
@property (copy, readonly) NSString *profile;     // "" = the first profile; otherwise a profile id (its own cookies, sign-ins, history and tabs)
- (WKWebViewConfiguration *)pageConfig;           // the engine set-up for this window's pages (private, profile or main)
- (void)profileMenu:(id)s;
- (void)newProfile:(id)s;
- (instancetype)initPrivate:(BOOL)priv state:(NSDictionary *)state;
- (NSDictionary *)sessionDict;
- (void)scheduleSave;
@property (strong) NSMutableArray<VTab *> *tabs;
@property (strong) VTab *current;
@property (strong) VSidebar *sidebar;
@property (strong) NSScrollView *sideScroll;
@property (strong) VToolbar *toolbar;
@property (strong) VBookmarksBar *bookmarksBar;
@property (strong) NSView *content;
@property (strong) VHome *home;
@property (strong) VFindBar *findBar;
@property (strong) NSView *railDock;
@property (strong) NSView *nowPlaying;
@property (weak) VTab *mediaTab;   // the tab whose music the sidebar player controls
@property (strong) NSArray<VTab *> *splitPair;   // two tabs sharing the page area, left then right
@property CGFloat splitRatio;
@property (strong) NSView *splitDivider, *splitMark;
@property (strong) id splitMonitor;
@property (strong) VSuggest *suggest;
@property (strong) NSMutableArray *closed;
@property (strong) NSTextField *toast;
- (void)newTab:(NSURL *)u select:(BOOL)sel;
- (void)selectTab:(VTab *)t;
- (void)closeTab:(VTab *)t;
- (void)go:(NSString *)input;
- (void)openURL:(NSURL *)u newTab:(BOOL)nt;
- (void)layout;
- (void)refreshChrome;
- (void)tabMenu:(VTab *)t at:(NSPoint)p inView:(NSView *)v;
- (void)moveTab:(VTab *)t to:(NSInteger)i;
- (void)togglePin:(VTab *)t;
- (void)saveSession;
- (void)focusAddress;
- (void)showToast:(NSString *)s;
- (void)pageChanged:(VPage *)p;
- (void)showLink:(NSString *)u;
- (void)findCount:(int)count active:(int)active;
- (void)newTabWithPage:(VPage *)p url:(NSURL *)u select:(BOOL)sel;
- (void)applyTheme;
- (void)openDownloads:(id)s;
- (void)useSuggestion:(NSDictionary *)it newTab:(BOOL)nt;
- (void)saveData:(NSData *)data name:(NSString *)name;
- (NSURL *)downloadFolder;
@end

@interface VWindow (Downloads)
- (void)showDownloads:(id)s;
@end

@interface VWindow (Private)
- (void)goHome:(id)s;
- (void)moveCurrentToNewWindow:(id)s;
- (void)showFind:(id)s;
- (void)find:(BOOL)backwards restart:(BOOL)restart;
@end

@interface VWindow (Tools)
- (void)toggleReader:(id)s;
- (void)exportPDF:(id)s;
- (void)saveWebArchive:(id)s;
- (void)sharePage:(id)s;
- (void)emailLink:(id)s;
- (void)openFile:(id)s;
- (void)findSelection:(id)s;
- (void)showInspector:(id)s;
- (void)showConsole:(id)s;
- (void)closeOtherTabs:(id)s;
- (void)moveTabLeft:(id)s;
- (void)moveTabRight:(id)s;
- (void)peekURL:(NSURL *)u;
- (void)peekLink:(NSMenuItem *)m;
- (void)closePeek:(id)s;
@end

@interface VWindow (Split)
- (void)placePages;
- (void)endSplit;
- (void)toggleSplit:(id)s;
- (void)splitWith:(VTab *)t;
- (void)splitLink:(NSMenuItem *)m;
- (void)menuSplit:(NSMenuItem *)m;
- (void)swapSplit:(id)s;
@end

@interface VWindow (Media)
- (void)updateNowPlaying;
- (void)autoPiPLeaving:(VTab *)old entering:(VTab *)t;
@end

@interface VWindow (Cosmetic)
- (void)blockElement:(id)s;
- (void)undoLastElement:(NSMenuItem *)i;
- (void)resetElements:(NSMenuItem *)i;
@end

@interface VWindow (Internal)
- (void)openInternal:(NSString *)name;
- (void)showHistory:(id)s;
- (void)showBookmarks:(id)s;
- (void)bookmarkAllTabs:(id)s;
- (void)showDownloadManager:(id)s;
- (void)showSettingsSection:(NSString *)section;
@end

static VWindow *gWin;                       // the browser window you're using (the last one that was key)

// Profiles: every profile has its own website data (cookies, sign-ins, site storage), history and open tabs.
// The first profile is the one Flint always had (WebKit's default data); others get their own data store.
static NSArray<NSDictionary *> *Profiles(void) {
    NSMutableArray *a = [NSMutableArray arrayWithObject:@{@"id": @"", @"name": [Defaults() stringForKey:kMainProfileName] ?: @"Personal"}];
    for (NSDictionary *p in [Defaults() arrayForKey:kProfiles] ?: @[]) if ([p isKindOfClass:NSDictionary.class] && [p[@"id"] length]) [a addObject:p];
    return a;
}
// Calm, distinct colours (no reds or yellows): a profile is recognised at a glance by its dot and its window's tint.
static NSArray<NSArray *> *ProfileColors(void) {
    return @[@[@"Graphite", @0x8E8E93], @[@"Ocean", @0x5B8DEF], @[@"Teal", @0x3BA99C], @[@"Violet", @0x8B7CF6], @[@"Sage", @0x7FA36B], @[@"Slate", @0x64748B]];
}
static NSInteger ProfileColorIndex(NSString *pid) {
    if (!pid.length) return [Defaults() objectForKey:kMainProfileColor] ? [Defaults() integerForKey:kMainProfileColor] : 0;
    NSArray *all = Profiles();
    for (NSUInteger i = 0; i < all.count; i++) if ([all[i][@"id"] isEqualToString:pid]) return all[i][@"color"] ? [all[i][@"color"] integerValue] : (NSInteger)(i % ProfileColors().count);
    return 0;
}
static NSColor *ProfileColor(NSString *pid) {
    NSArray *c = ProfileColors(); NSInteger i = ProfileColorIndex(pid);
    return Hex((uint32_t)[c[(NSUInteger)MAX(0, MIN((NSInteger)c.count - 1, i))][1] unsignedIntValue]);
}
// The profile's avatar: its initial on its colour.
static NSImage *ProfileAvatar(NSString *pid, NSString *name, CGFloat size) {
    NSColor *c = ProfileColor(pid);
    NSString *initial = name.length ? [[name substringToIndex:[name rangeOfComposedCharacterSequenceAtIndex:0].length] uppercaseString] : @"•";
    return [NSImage imageWithSize:NSMakeSize(size, size) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [c setFill]; [[NSBezierPath bezierPathWithOvalInRect:r] fill];
        NSDictionary *a = @{NSFontAttributeName: UIFont(size * 0.56, NSFontWeightSemibold), NSForegroundColorAttributeName: NSColor.whiteColor};
        NSSize s = [initial sizeWithAttributes:a];
        [initial drawAtPoint:NSMakePoint(round((size - s.width) / 2), round((size - s.height) / 2)) withAttributes:a];
        return YES;
    }];
}
static NSString *ProfileName(NSString *pid) {
    for (NSDictionary *p in Profiles()) if ([p[@"id"] isEqualToString:pid ?: @""]) return p[@"name"];
    return @"Personal";
}
static NSMutableDictionary<NSString *, WKWebsiteDataStore *> *gProfileStores;
static NSMutableDictionary<NSString *, NSArray<WKContentRuleList *> *> *gExtRuleLists;   // extension id → its compiled blocking rules
static WKWebsiteDataStore *ProfileStore(NSString *pid) {
    if (!pid.length) return WKWebsiteDataStore.defaultDataStore;
    if (!gProfileStores) gProfileStores = [NSMutableDictionary dictionary];
    NSMutableDictionary *stores = gProfileStores;
    if (stores[pid]) return stores[pid];
    WKWebsiteDataStore *s = nil;
    if (@available(macOS 14.0, *)) { NSUUID *u = [[NSUUID alloc] initWithUUIDString:pid]; if (u) s = [WKWebsiteDataStore dataStoreForIdentifier:u]; }
    if (!s) s = WKWebsiteDataStore.defaultDataStore;   // before macOS 14 WebKit has no separate stores: profiles share website data
    stores[pid] = s;
    return s;
}
@class VWindow;
static BOOL gQuitting;   // set once Flint has decided to quit: windows closing now must not overwrite the saved tabs
static void SettingsOp(NSString *op, NSDictionary *b, VWindow *win, void (^reply)(id, NSString *));   // at launch, restored tabs wait until the extensions are up (then load)
static NSMutableArray<VWindow *> *gWindows;  // every open browser window, oldest first

// The browser window a view, window or tab belongs to; falls back to the active one.
static VWindow *WinFor(id o) {
    NSWindow *w = [o isKindOfClass:NSView.class] ? ((NSView *)o).window : [o isKindOfClass:NSWindow.class] ? o : nil;
    while (w.parentWindow) w = w.parentWindow;
    id c = w.windowController;
    return [c isKindOfClass:VWindow.class] ? c : gWin;
}
static NSArray<VTab *> *AllTabs(BOOL includePrivate) {
    NSMutableArray *a = [NSMutableArray array];
    for (VWindow *w in gWindows) if (includePrivate || !w.isPrivate) [a addObjectsFromArray:w.tabs];
    return a;
}
static VWindow *WinOfWeb(WKWebView *v) { for (VTab *t in AllTabs(YES)) if (t.web.web == v) return t.owner; return nil; }

@class FExtHost;
@interface FExtHost : NSObject <WKScriptMessageHandlerWithReply, WKURLSchemeHandler>
+ (instancetype)shared;
- (void)install:(WKUserContentController *)ucc config:(WKWebViewConfiguration *)cfg;
- (void)tab:(VTab *)t event:(NSString *)kind;
- (NSArray *)extensions;
- (void)openPopup:(id)ext from:(NSView *)anchor;
- (void)start;
- (void)evalIn:(NSString *)where code:(NSString *)code;
- (NSImage *)iconFor:(id)ext;
- (NSString *)nameForID:(NSString *)ident;
- (NSImage *)iconForID:(NSString *)ident;
- (NSArray<NSDictionary *> *)allExtensionInfo;
- (void)setExtension:(NSString *)ident enabled:(BOOL)on;
- (void)removeExtension:(NSString *)ident;
- (void)installFromWebStore:(NSString *)input done:(void (^)(NSString *name, NSString *error))done;
- (BOOL)openOptionsForID:(NSString *)ident;
- (BOOL)hasOptionsForID:(NSString *)ident;
- (void)addMenuItemsTo:(NSMenu *)menu context:(NSDictionary *)ctx pageURL:(NSString *)page view:(WKWebView *)v;   // chrome.contextMenus items
@end

@interface VApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property BOOL quitConfirmed;
@property (strong) VWindow *win;
- (void)installUpdate:(id)s;
- (void)applyThrottleNow;
@end
static VApp *gApp;
#pragma mark - Tab

@implementation VTab
@end

#pragma mark - History

// Kept as a small JSON file: one entry per URL with title, visit count and last visit.
@interface VHistory ()
@property (copy) NSString *file;
@property (strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *byURL;
@property BOOL dirty;
@end

@implementation VHistory

static NSMutableDictionary<NSString *, VHistory *> *gHistories;
+ (instancetype)forProfile:(NSString *)profile {
    NSString *pid = profile ?: @"";
    if (!gHistories) gHistories = [NSMutableDictionary dictionary];
    VHistory *h = gHistories[pid];
    if (!h) { h = [VHistory new]; h.file = pid.length ? [NSString stringWithFormat:@"history-%@.json", pid] : @"history.json"; [h load]; gHistories[pid] = h; }
    return h;
}
+ (instancetype)shared { return [self forProfile:gWin && !gWin.isPrivate ? gWin.profile : @""]; }
+ (void)flushAll { for (VHistory *h in gHistories.allValues) [h flush]; }

- (void)load {
    self.byURL = [NSMutableDictionary dictionary];
    NSData *d = [NSData dataWithContentsOfFile:SupportFile(self.file)];
    NSArray *a = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    if ([a isKindOfClass:NSArray.class]) for (NSMutableDictionary *e in a) if ([e isKindOfClass:NSDictionary.class] && e[@"u"]) self.byURL[e[@"u"]] = e;
    [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer *t) { [self flush]; }];
}

- (void)flush {
    if (!self.dirty) return;
    self.dirty = NO;
    NSArray *all = [self.byURL.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"t"] compare:a[@"t"]];
    }];
    if (all.count > 6000) all = [all subarrayWithRange:NSMakeRange(0, 6000)];
    NSData *d = [NSJSONSerialization dataWithJSONObject:all options:0 error:nil];
    [d writeToFile:SupportFile(self.file) atomically:YES];
}

- (void)visit:(NSURL *)u title:(NSString *)t {
    if (![u.scheme hasPrefix:@"http"]) return;
    NSString *k = u.absoluteString;
    NSMutableDictionary *e = self.byURL[k];
    if (!e) { e = [NSMutableDictionary dictionaryWithDictionary:@{@"u": k, @"c": @0}]; self.byURL[k] = e; }
    e[@"c"] = @([e[@"c"] integerValue] + 1);
    e[@"t"] = @(NSDate.date.timeIntervalSince1970);
    if (t.length) e[@"ti"] = t;
    self.dirty = YES;
}

static double Frecency(NSDictionary *e) {
    double age = (NSDate.date.timeIntervalSince1970 - [e[@"t"] doubleValue]) / 86400.0;
    return [e[@"c"] doubleValue] * (age < 1 ? 4 : age < 7 ? 2 : age < 30 ? 1 : 0.4);
}

- (NSArray<NSDictionary *> *)match:(NSString *)q limit:(NSUInteger)n {
    q = q.lowercaseString;
    if (!q.length) return @[];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSDictionary *e in self.byURL.allValues) {
        NSString *u = [e[@"u"] lowercaseString];
        NSString *bare = [[u stringByReplacingOccurrencesOfString:@"https://" withString:@""] stringByReplacingOccurrencesOfString:@"http://" withString:@""];
        if ([bare hasPrefix:@"www."]) bare = [bare substringFromIndex:4];
        double s = 0;
        if ([bare hasPrefix:q]) s = 100;
        else if ([u containsString:q]) s = 20;
        else if ([[e[@"ti"] lowercaseString] containsString:q]) s = 15;
        if (s > 0) [hits addObject:@[@(s + Frecency(e) + (bare.length < 30 ? 5 : 0)), e]];
    }
    [hits sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *h in hits) { [out addObject:h[1]]; if (out.count >= n) break; }
    return out;
}

- (NSArray<NSDictionary *> *)topSites:(NSUInteger)n {
    // one tile per site: the most-used page on each host
    NSMutableDictionary<NSString *, NSArray *> *best = [NSMutableDictionary dictionary];
    for (NSDictionary *e in self.byURL.allValues) {
        NSURL *u = [NSURL URLWithString:e[@"u"]]; NSString *h = HostOf(u);
        if (!h.length) continue;
        double s = Frecency(e);
        NSArray *cur = best[h];
        double total = (cur ? [cur[0] doubleValue] : 0) + s;
        NSDictionary *page = cur && [cur[2] doubleValue] >= s ? cur[1] : e;
        best[h] = @[@(total), page, @(MAX(s, cur ? [cur[2] doubleValue] : 0))];
    }
    NSArray *sorted = [best.allValues sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *x in sorted) {
        NSDictionary *e = x[1];
        NSURL *u = [NSURL URLWithString:e[@"u"]];
        [out addObject:@{@"u": [NSString stringWithFormat:@"%@://%@/", u.scheme ?: @"https", u.host ?: @""], @"ti": HostOf(u)}];
        if (out.count >= n) break;
    }
    return out;
}

- (NSArray<NSDictionary *> *)recent:(NSUInteger)n {
    NSArray *all = [self.byURL.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"t"] compare:a[@"t"]]; }];
    return all.count > n ? [all subarrayWithRange:NSMakeRange(0, n)] : all;
}

- (void)clear { [self.byURL removeAllObjects]; self.dirty = YES; [self flush]; }

- (NSArray<NSDictionary *> *)all {
    return [self.byURL.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"t"] compare:a[@"t"]]; }];
}
- (void)removeURLs:(NSArray<NSString *> *)urls {
    for (NSString *u in urls) if ([u isKindOfClass:NSString.class]) [self.byURL removeObjectForKey:u];
    self.dirty = YES; [self flush];
}
- (void)removeHost:(NSString *)host {
    if (!host.length) return;
    for (NSString *k in self.byURL.allKeys) if ([HostOf([NSURL URLWithString:k]) isEqualToString:host]) [self.byURL removeObjectForKey:k];
    self.dirty = YES; [self flush];
}
- (void)removeSince:(NSTimeInterval)since {
    for (NSString *k in self.byURL.allKeys) if ([self.byURL[k][@"t"] doubleValue] >= since) [self.byURL removeObjectForKey:k];
    self.dirty = YES; [self flush];
}

@end

#pragma mark - Bookmarks

static NSString *HeliumProfile(void) {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/net.imput.helium"];
    for (NSString *p in @[@"Default", @"Profile 1", @"Profile 2"]) {
        NSString *d = [base stringByAppendingPathComponent:p];
        if ([NSFileManager.defaultManager fileExistsAtPath:[d stringByAppendingPathComponent:@"Bookmarks"]]) return d;
    }
    return nil;
}

static NSInteger gBmVersion = 1;   // bumps on every save, so the bookmark manager can tell when its copy is stale

@implementation VBookmarks

+ (instancetype)shared {
    static VBookmarks *b; static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [VBookmarks new]; [b load]; });
    return b;
}

static NSMutableDictionary *ConvertChromeNode(NSDictionary *n) {
    if ([n[@"type"] isEqualToString:@"folder"]) {
        NSMutableArray *kids = [NSMutableArray array];
        for (NSDictionary *c in n[@"children"]) { NSMutableDictionary *k = ConvertChromeNode(c); if (k) [kids addObject:k]; }
        return [NSMutableDictionary dictionaryWithDictionary:@{@"name": n[@"name"] ?: @"Folder", @"children": kids}];
    }
    if (![n[@"url"] isKindOfClass:NSString.class]) return nil;
    return [NSMutableDictionary dictionaryWithDictionary:@{@"name": n[@"name"] ?: @"", @"url": n[@"url"]}];
}

- (void)load {
    NSData *d = [NSData dataWithContentsOfFile:SupportFile(@"bookmarks.json")];
    id a = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    if ([a isKindOfClass:NSMutableArray.class]) { self.bar = a; return; }
    // First run: bring over Helium's bookmarks bar (Helium itself is untouched).
    self.bar = [NSMutableArray array];
    NSString *prof = HeliumProfile();
    NSData *hd = prof ? [NSData dataWithContentsOfFile:[prof stringByAppendingPathComponent:@"Bookmarks"]] : nil;
    NSDictionary *root = hd ? [NSJSONSerialization JSONObjectWithData:hd options:0 error:nil] : nil;
    for (NSDictionary *n in root[@"roots"][@"bookmark_bar"][@"children"]) { NSMutableDictionary *k = ConvertChromeNode(n); if (k) [self.bar addObject:k]; }
    NSMutableArray *other = [NSMutableArray array];
    for (NSDictionary *n in root[@"roots"][@"other"][@"children"]) { NSMutableDictionary *k = ConvertChromeNode(n); if (k) [other addObject:k]; }
    if (other.count) [self.bar addObject:[NSMutableDictionary dictionaryWithDictionary:@{@"name": @"Other bookmarks", @"children": other}]];
    [self save];
}

- (void)save {
    gBmVersion++;
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.bar options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:SupportFile(@"bookmarks.json") atomically:YES];
}

static NSMutableDictionary *FindIn(NSArray *list, NSString *url, NSMutableArray **parent) {
    for (NSMutableDictionary *n in list) {
        if (n[@"children"]) { NSMutableDictionary *r = FindIn(n[@"children"], url, parent); if (r) return r; }
        else if ([n[@"url"] isEqualToString:url]) { if (parent) *parent = (NSMutableArray *)list; return n; }
    }
    return nil;
}
- (NSMutableDictionary *)find:(NSString *)url { return url ? FindIn(self.bar, url, NULL) : nil; }

- (void)toggle:(NSString *)url title:(NSString *)title {
    if (!url) return;
    NSMutableArray *parent = nil;
    NSMutableDictionary *n = FindIn(self.bar, url, &parent);
    if (n) [parent removeObject:n];
    else [self.bar addObject:[NSMutableDictionary dictionaryWithDictionary:@{@"name": title ?: @"", @"url": url}]];
    [self save];
}

static void Collect(NSArray *list, NSMutableArray *out) {
    for (NSDictionary *n in list) { if (n[@"children"]) Collect(n[@"children"], out); else [out addObject:n]; }
}
- (NSArray<NSDictionary *> *)allURLs { NSMutableArray *o = [NSMutableArray array]; Collect(self.bar, o); return o; }

@end

#pragma mark - Favicons

// Icons are remembered per site (host), in memory and as small PNGs on disk.
@interface VFavicons ()
@property (strong) NSCache *mem;
@property (strong) NSMutableSet *pending;
@end

@implementation VFavicons

+ (instancetype)shared {
    static VFavicons *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [VFavicons new]; f.mem = [NSCache new]; f.pending = [NSMutableSet set]; [f dropWhiteTiles]; [f importHelium]; });
    return f;
}

static NSString *IconDir(void) {
    NSString *d = SupportFile(@"icons");
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
static NSString *IconKey(NSString *url) {
    NSString *h = HostOf([NSURL URLWithString:url]);
    return h.length ? h : nil;
}

- (NSImage *)iconForURL:(NSString *)url {
    NSString *k = IconKey(url); if (!k) return nil;
    NSImage *im = [self.mem objectForKey:k];
    if (im) return im;
    NSString *f = [[IconDir() stringByAppendingPathComponent:k] stringByAppendingPathExtension:@"png"];
    im = [[NSImage alloc] initWithContentsOfFile:f];
    if (im) [self.mem setObject:im forKey:k];
    return im;
}

- (void)remember:(NSImage *)im forURL:(NSString *)url {
    NSString *k = IconKey(url); if (!k || !im) return;
    [self.mem setObject:im forKey:k];
    NSBitmapImageRep *rep = nil;
    NSImage *small = [NSImage imageWithSize:NSMakeSize(32, 32) flipped:NO drawingHandler:^BOOL(NSRect r) { [im drawInRect:r]; return YES; }];
    CGImageRef cg = [small CGImageForProposedRect:NULL context:nil hints:nil];
    if (cg) rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[[IconDir() stringByAppendingPathComponent:k] stringByAppendingPathExtension:@"png"] atomically:YES];
}

// Where a site's icon comes from, in order: the icon the page declares, /favicon.ico, the <link rel=icon>
// in the site's home page HTML, and finally DuckDuckGo's icon service (no cookies, nothing about you).
- (void)fetchFor:(NSURL *)page href:(NSString *)href done:(void (^)(NSImage *))done {
    NSString *k = HostOf(page);
    if (!k.length || [self.pending containsObject:k]) return;
    [self.pending addObject:k];
    [self fetchFor:page href:href stage:href.length ? 0 : 1 done:done];
}

static NSMutableURLRequest *IconRequest(NSURL *u) {
    NSMutableURLRequest *q = [NSMutableURLRequest requestWithURL:u cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:12];
    [q setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    return q;
}

- (void)fetchFor:(NSURL *)page href:(NSString *)href stage:(int)stage done:(void (^)(NSImage *))done {
    NSString *k = HostOf(page);
    void (^next)(void) = ^{
        if (stage == 0) [self fetchFor:page href:nil stage:1 done:done];
        else if (stage == 1) [self fetchFor:page href:nil stage:2 done:done];
        else if (stage == 2 || stage == 3) [self fetchFor:page href:nil stage:4 done:done];
        else [self.pending removeObject:k];
    };
    void (^tryImage)(NSURL *) = ^(NSURL *u) {
        [[NSURLSession.sharedSession dataTaskWithRequest:IconRequest(u) completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            NSString *type = [(NSHTTPURLResponse *)r valueForHTTPHeaderField:@"Content-Type"] ?: @"";
            NSImage *im = (d.length && ![type hasPrefix:@"text/html"]) ? [[NSImage alloc] initWithData:d] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (im && im.size.width > 0) { [self.pending removeObject:k]; [self remember:im forURL:page.absoluteString]; if (done) done(im); }
                else next();
            });
        }] resume];
    };
    if (stage == 0) { NSURL *u = [NSURL URLWithString:href relativeToURL:page]; if (u) tryImage(u); else next(); return; }
    if (stage == 1) { tryImage([NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/favicon.ico", page.scheme, page.host]]); return; }
    if (stage == 4) { tryImage([NSURL URLWithString:[NSString stringWithFormat:@"https://icons.duckduckgo.com/ip3/%@.ico", page.host]]); return; }
    // stage 2: read the site's HTML for its declared icon
    NSURL *home = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/", page.scheme, page.host]];
    [[NSURLSession.sharedSession dataTaskWithRequest:IconRequest(home) completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *html = d.length ? [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(d.length, 200000))] encoding:NSUTF8StringEncoding] : nil;
        NSString *found = nil;
        if (html) {
            NSRegularExpression *link = [NSRegularExpression regularExpressionWithPattern:@"<link\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
            NSRegularExpression *rel = [NSRegularExpression regularExpressionWithPattern:@"rel\\s*=\\s*[\"']?([^\"'>]*)" options:NSRegularExpressionCaseInsensitive error:nil];
            NSRegularExpression *hrefRx = [NSRegularExpression regularExpressionWithPattern:@"href\\s*=\\s*[\"']([^\"']+)" options:NSRegularExpressionCaseInsensitive error:nil];
            for (NSTextCheckingResult *m in [link matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
                NSString *tag = [html substringWithRange:m.range];
                NSTextCheckingResult *rm = [rel firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
                NSTextCheckingResult *hm = [hrefRx firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
                if (!rm || !hm) continue;
                NSString *rv = [tag substringWithRange:[rm rangeAtIndex:1]].lowercaseString;
                if (![rv containsString:@"icon"]) continue;
                NSString *h = [[tag substringWithRange:[hm rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
                if ([rv containsString:@"apple-touch"]) { if (!found) found = h; continue; }   // a last resort: opaque tile
                found = h;
                if ([tag containsString:@"32x32"] || [tag containsString:@"svg"]) break;
            }
        }
        NSURL *base = r.URL ?: home;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *u = found ? [NSURL URLWithString:found relativeToURL:base] : nil;
            if (u) [self fetchStage3:u page:page key:k done:done]; else next();
        });
    }] resume];
}
- (void)fetchStage3:(NSURL *)u page:(NSURL *)page key:(NSString *)k done:(void (^)(NSImage *))done {
    [[NSURLSession.sharedSession dataTaskWithRequest:IconRequest(u) completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSImage *im = d.length ? [[NSImage alloc] initWithData:d] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (im && im.size.width > 0) { [self.pending removeObject:k]; [self remember:im forURL:page.absoluteString]; if (done) done(im); }
            else [self fetchFor:page href:nil stage:4 done:done];
        });
    }] resume];
}

// Icons saved before Flint preferred real favicons were often apple-touch tiles: opaque squares with a white
// background. Those are removed once so the proper icon is fetched (or re-read from Helium) instead.
static BOOL IsWhiteTile(NSBitmapImageRep *r) {
    if (!r || r.pixelsWide < 8 || r.pixelsHigh < 8) return NO;
    NSInteger w = r.pixelsWide - 1, h = r.pixelsHigh - 1;
    NSInteger pts[4][2] = {{1, 1}, {w - 1, 1}, {1, h - 1}, {w - 1, h - 1}};
    for (int i = 0; i < 4; i++) {
        NSColor *c = [[r colorAtX:pts[i][0] y:pts[i][1]] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (!c || c.alphaComponent < 0.9 || c.redComponent < 0.9 || c.greenComponent < 0.9 || c.blueComponent < 0.9) return NO;
    }
    return YES;
}
- (void)dropWhiteTiles {
    if ([Defaults() boolForKey:@"iconsTilesDropped"]) return;
    [Defaults() setBool:YES forKey:@"iconsTilesDropped"];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *f in [fm contentsOfDirectoryAtPath:IconDir() error:nil]) {
        NSString *p = [IconDir() stringByAppendingPathComponent:f];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (d && IsWhiteTile([NSBitmapImageRep imageRepWithData:d])) [fm removeItemAtPath:p error:nil];
    }
    [Defaults() removeObjectForKey:@"iconsImported"];   // let Helium's real favicons fill the gaps
}

// Helium keeps favicons in an SQLite file; copy the ones for bookmarked pages once.
- (void)importHelium {
    if ([Defaults() boolForKey:@"iconsImported"]) return;
    [Defaults() setBool:YES forKey:@"iconsImported"];
    NSString *prof = HeliumProfile(); if (!prof) return;
    NSString *tmp = SupportFile(@"helium-icons.db");
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *sfx in @[@"", @"-wal"]) {
        NSString *src = [[prof stringByAppendingPathComponent:@"Favicons"] stringByAppendingString:sfx];
        [fm removeItemAtPath:[tmp stringByAppendingString:sfx] error:nil];
        if ([fm fileExistsAtPath:src]) [fm copyItemAtPath:src toPath:[tmp stringByAppendingString:sfx] error:nil];
    }
    sqlite3 *db = NULL;
    if (sqlite3_open(tmp.fileSystemRepresentation, &db) == SQLITE_OK) {
        sqlite3_stmt *st = NULL;
        const char *sql = "SELECT b.image_data FROM icon_mapping m JOIN favicons f ON f.id = m.icon_id JOIN favicon_bitmaps b ON b.icon_id = m.icon_id WHERE m.page_url = ? AND f.icon_type = 1 ORDER BY ABS(b.width - 32) LIMIT 1";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            for (NSDictionary *bm in [VBookmarks.shared allURLs]) {
                NSString *url = bm[@"url"];
                sqlite3_reset(st);
                sqlite3_bind_text(st, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
                if (sqlite3_step(st) == SQLITE_ROW) {
                    const void *blob = sqlite3_column_blob(st, 0); int n = sqlite3_column_bytes(st, 0);
                    NSImage *im = blob && n > 0 ? [[NSImage alloc] initWithData:[NSData dataWithBytes:blob length:(NSUInteger)n]] : nil;
                    if (im && ![self iconForURL:url]) [self remember:im forURL:url];
                }
            }
            sqlite3_finalize(st);
        }
        sqlite3_close(db);
    }
    for (NSString *sfx in @[@"", @"-wal", @"-shm"]) [fm removeItemAtPath:[tmp stringByAppendingString:sfx] error:nil];
}

@end
#pragma mark - Ad and tracker blocking

// Filter lists are downloaded here; Flint's request filter reads them and cancels requests to ad and tracker hosts.

static NSArray<NSArray<NSString *> *> *FilterLists(void) {
    return @[@[@"easylist", @"EasyList (ads)", @"https://easylist.to/easylist/easylist.txt"],
             @[@"easyprivacy", @"EasyPrivacy (trackers)", @"https://easylist.to/easylist/easyprivacy.txt"],
             @[@"pgl", @"Peter Lowe's ad and tracking servers", @"https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext"],
             @[@"cookies", @"Cookie notices (Fanboy)", @"https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"],
             @[@"annoyances", @"Annoyances (Fanboy)", @"https://secure.fanboy.co.nz/fanboy-annoyance.txt"]];
}
static NSSet<NSString *> *ListsOn(void) {
    NSArray *a = [Defaults() arrayForKey:kListsOn];
    return [NSSet setWithArray:a ?: @[@"easylist", @"easyprivacy", @"pgl", @"cookies"]];
}

@interface VBlocker ()
@property BOOL busy;
@property (strong) NSMutableArray *waiters;
@end

@implementation VBlocker

+ (instancetype)shared {
    static VBlocker *b; static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [VBlocker new]; b.waiters = [NSMutableArray array]; b.status = @"Not ready"; });
    return b;
}

static NSString *ListDir(void) {
    NSString *d = SupportFile(@"lists");
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

- (NSString *)updatedText {
    double t = [Defaults() doubleForKey:kListsUpdated];
    if (t <= 0) return @"never";
    NSDateFormatter *f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle; f.timeStyle = NSDateFormatterNoStyle;
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
}

- (void)prepare:(void (^)(void))ready {
    double age = NSDate.date.timeIntervalSince1970 - [Defaults() doubleForKey:kListsUpdated];
    self.status = [NSString stringWithFormat:@"Ready · updated %@", [self updatedText]];
    BOOL empty = [NSFileManager.defaultManager contentsOfDirectoryAtPath:ListDir() error:nil].count == 0;
    if (age > 7 * 86400 || empty) [self updateLists:empty done:ready];
    else if (ready) ready();
}

- (void)updateLists:(BOOL)force done:(void (^)(void))done {
    if (done) [self.waiters addObject:[done copy]];
    if (self.busy) return;
    self.busy = YES;
    self.status = @"Downloading filter lists…";
    NSSet *on = ListsOn();
    NSString *dir = ListDir();
    dispatch_group_t g = dispatch_group_create();
    for (NSArray *l in FilterLists()) {
        NSString *file = [[dir stringByAppendingPathComponent:l[0]] stringByAppendingPathExtension:@"txt"];
        if (![on containsObject:l[0]]) { [NSFileManager.defaultManager removeItemAtPath:file error:nil]; continue; }
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
        if (!force && attrs && -[attrs.fileModificationDate timeIntervalSinceNow] < 6 * 86400) continue;
        dispatch_group_enter(g);
        [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:l[2]] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            if (d.length > 1000 && [(NSHTTPURLResponse *)r statusCode] == 200) [d writeToFile:file atomically:YES];
            dispatch_group_leave(g);
        }] resume];
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        FlintReloadBlocklists();
        [Defaults() setDouble:NSDate.date.timeIntervalSince1970 forKey:kListsUpdated];
        self.busy = NO;
        self.status = [NSString stringWithFormat:@"Ready · updated %@", [self updatedText]];
        NSArray *w = self.waiters.copy; [self.waiters removeAllObjects];
        for (void (^b)(void) in w) b();
    });
}

@end
#pragma mark - Downloads: the list behind the toolbar's downloads button

@interface VDownload : NSObject
@property (copy) NSString *name, *path, *url;
@property (copy) NSString *state;          // running, done, failed, cancelled
@property int64_t received, total;
@property double speed;                    // bytes per second
@property NSTimeInterval started, lastTick, ended;
@property int64_t lastBytes;
@property (weak) WKDownload *wk;
@property (strong) NSData *resume;
@property (weak) WKWebView *view;
// the accelerator (Flint's own downloader): several connections at once, each fetching a slice of the file
@property (copy) NSString *ident, *kind, *partPath, *referer, *ua, *cookie, *error;   // kind: "accel" or "webkit"
@property (strong) NSMutableArray<NSMutableDictionary *> *segs;   // {s: first byte, e: last byte (-1 unknown), g: bytes got, tries}
@property (strong) NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *tasks;
@property (strong) NSFileHandle *fh;
@property BOOL resumable, isPrivate;
@property NSInteger conns;
@property double peak;
@end
@implementation VDownload
@end

@interface VDownloads : NSObject
@property (strong) NSMutableArray<VDownload *> *items;
+ (instancetype)shared;
- (VDownload *)startFor:(WKDownload *)d dest:(NSURL *)dest;
- (void)finished:(WKDownload *)d;
- (void)failed:(WKDownload *)d resume:(NSData *)r;
- (double)activeProgress;    // -1 when nothing is downloading
- (BOOL)worthShowing;        // something downloading, or just finished: the toolbar shows its button
- (void)save;
- (void)changed;
- (VDownload *)byId:(NSString *)ident;
@end

#pragma mark - Menus

// Flint draws its own menus. The code still builds ordinary NSMenus (titles, actions, checkmarks,
// shortcuts, submenus); PopMenu shows them in a quiet rounded panel with icons and soft hover,
// instead of the stock macOS menu. Keyboard works as you'd expect: arrows, return, esc, letters.

static NSString *MenuSymbolFor(NSString *t) {
    static NSDictionary *m;
    if (!m) m = @{@"New Tab": @"plus", @"New Window": @"macwindow.badge.plus", @"New Private Window": @"eye.slash",
                  @"Reopen Closed Tab": @"arrow.uturn.backward", @"History": @"clock.arrow.circlepath", @"Show All History": @"clock.arrow.circlepath",
                  @"Bookmarks": @"book", @"Show All Bookmarks": @"book", @"Downloads": @"tray.and.arrow.down", @"Extensions": @"puzzlepiece.extension",
                  @"Settings…": @"gearshape", @"Hide Bookmarks Bar": @"menubar.rectangle", @"Show Bookmarks Bar": @"menubar.rectangle",
                  @"Reload Tab": @"arrow.clockwise", @"Pin Tab": @"pin", @"Unpin Tab": @"pin.slash", @"Duplicate Tab": @"plus.square.on.square",
                  @"Copy Link": @"link", @"Bookmark Tab": @"star", @"Bookmark This Page": @"star", @"Remove Bookmark": @"star.slash",
                  @"Mute Tab": @"speaker.slash", @"Unmute Tab": @"speaker.wave.2", @"Put Tab to Sleep": @"moon.zzz",
                  @"New Split View": @"rectangle.split.2x1", @"Split View with Current Tab": @"rectangle.split.2x1", @"Exit Split View": @"rectangle",
                  @"Swap Sides": @"arrow.left.arrow.right", @"Move Tab to New Window": @"macwindow", @"Close Tab": @"xmark",
                  @"Close Other Tabs": @"xmark.square", @"Close Tabs Below": @"arrow.down.to.line", @"Address Bar Width": @"arrow.left.and.right",
                  @"Reset Toolbar": @"arrow.counterclockwise", @"Customise in Settings…": @"slider.horizontal.3",
                  @"Block Element…": @"hand.point.up.left", @"Undo Last": @"arrow.uturn.backward", @"Show All Hidden": @"eye",
                  @"Open in New Tab": @"plus.square", @"Open in Background Tab": @"square.on.square", @"Open All in Tabs": @"square.stack",
                  @"Edit…": @"pencil", @"Rename…": @"pencil", @"Delete": @"trash", @"Remove": @"trash", @"New Folder…": @"folder.badge.plus",
                  @"Clear Browsing Data…": @"trash", @"Find…": @"text.magnifyingglass", @"Print…": @"printer", @"Share…": @"square.and.arrow.up",
                  @"Reader": @"doc.plaintext", @"Picture in Picture": @"pip", @"Zoom In": @"plus.magnifyingglass", @"Zoom Out": @"minus.magnifyingglass",
                  @"Manage Extensions": @"puzzlepiece.extension", @"Chrome Web Store": @"bag", @"Bookmark Manager": @"books.vertical"};
    return m[t];
}

static NSString *KeyGlyphs(NSMenuItem *i) {
    NSString *k = i.keyEquivalent; if (!k.length) return @"";
    NSEventModifierFlags f = i.keyEquivalentModifierMask;
    BOOL upper = ![k.lowercaseString isEqualToString:k];
    NSMutableString *s = [NSMutableString string];
    if (f & NSEventModifierFlagControl) [s appendString:@"⌃"];
    if (f & NSEventModifierFlagOption) [s appendString:@"⌥"];
    if ((f & NSEventModifierFlagShift) || upper) [s appendString:@"⇧"];
    if (f & NSEventModifierFlagCommand) [s appendString:@"⌘"];
    unichar c = [k characterAtIndex:0];
    NSString *key = c == '\r' || c == 3 ? @"↩" : c == 0x7f || c == 0x08 ? @"⌫" : c == 0x1b ? @"⎋" : c == ' ' ? @"Space" : c == '\t' ? @"⇥"
                  : c == NSLeftArrowFunctionKey ? @"←" : c == NSRightArrowFunctionKey ? @"→" : c == NSUpArrowFunctionKey ? @"↑" : c == NSDownArrowFunctionKey ? @"↓"
                  : k.uppercaseString;
    [s appendString:key];
    return s;
}

static BOOL MenuItemEnabled(NSMenuItem *i) {
    if (!i.enabled) return NO;
    if (i.submenu) return YES;
    if (!i.action) return NO;
    id t = i.target ?: [NSApp targetForAction:i.action to:nil from:i];
    if (!t || ![t respondsToSelector:i.action]) return NO;
    if (i.menu.autoenablesItems && [t respondsToSelector:@selector(validateMenuItem:)]) return [t validateMenuItem:i];
    return YES;
}
static BOOL MenuItemIsHeader(NSMenuItem *i) { return !i.separatorItem && !i.action && !i.submenu && i.title.length; }

// A menu can let its items be dragged, take drops, and offer a right-click menu per item (the bookmarks
// bar's folders do): the NSMenu carries a VMenuDropTarget that knows what the items stand for.
@protocol VMenuDropTarget <NSObject>
- (NSDragOperation)menu:(NSMenu *)m validateDrop:(id<NSDraggingInfo>)info before:(NSMenuItem *)item into:(NSMenuItem *)folder;
- (BOOL)menu:(NSMenu *)m acceptDrop:(id<NSDraggingInfo>)info before:(NSMenuItem *)item into:(NSMenuItem *)folder;
- (NSMenu *)menu:(NSMenu *)m contextMenuFor:(NSMenuItem *)item;
- (BOOL)menu:(NSMenu *)m beginDragFor:(NSMenuItem *)item event:(NSEvent *)e view:(NSView<NSDraggingSource> *)v;
- (BOOL)itemIsDraggable:(NSMenuItem *)item;
@end
static char kMenuDropKey;
static id<VMenuDropTarget> MenuDropTarget(NSMenu *m) { return m ? objc_getAssociatedObject(m, &kMenuDropKey) : nil; }

@class VMenuPanel;
static NSMutableArray<VMenuPanel *> *gMenus;   // open menus, outermost first
static id gMenuLocal, gMenuGlobal, gMenuResign;
static void CloseMenus(void);
static void CloseMenusFrom(VMenuPanel *c);
static void OpenMenuPanel(NSMenu *m, NSPoint topLeft, NSWindow *owner, VMenuPanel *parent, CGFloat flipX);

@interface VMenuView : NSView <NSDraggingSource>
@property NSInteger pressRow, dropRow;   // dropRow: insertion line before this row (rows.count = at the end)
@property NSInteger dropInto;            // a folder row the drop goes into
@property NSPoint pressAt;
@property (strong) NSMenu *source;
@property (strong) NSArray<NSMenuItem *> *items;
@property (strong) NSArray<NSValue *> *rects;
@property NSInteger hover;
@property BOOL gutter;
@property (weak) VMenuPanel *panel;
@property (strong) NSTimer *subTimer;
@end

@interface VMenuPanel : NSPanel
@property (strong) VMenuView *list;
@property (weak) VMenuPanel *parentMenu;
@property (weak) VMenuPanel *child;
@property (weak) NSWindow *owner;
@property NSInteger parentRow;
@end
@implementation VMenuPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static const CGFloat kMenuPad = 6, kMenuRow = 28, kMenuSep = 9, kMenuHead = 24;

@implementation VMenuView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (CGFloat)buildRows {
    NSMutableArray *items = [NSMutableArray array], *rects = [NSMutableArray array];
    BOOL gutter = NO;
    for (NSMenuItem *i in self.source.itemArray) {
        if (i.hidden || i.isAlternate) continue;
        if (i.separatorItem && (!items.count || [items.lastObject isSeparatorItem])) continue;   // no leading or doubled lines
        [items addObject:i];
        if (i.image || i.state == NSControlStateValueOn || MenuSymbolFor(i.title)) gutter = YES;
    }
    while ([items.lastObject isSeparatorItem]) [items removeLastObject];
    NSDictionary *ta = @{NSFontAttributeName: UIFont(13, NSFontWeightRegular)}, *ka = @{NSFontAttributeName: UIFont(12, NSFontWeightRegular)};
    CGFloat w = 0, y = kMenuPad;
    for (NSMenuItem *i in items) {
        CGFloat h = i.separatorItem ? kMenuSep : MenuItemIsHeader(i) ? kMenuHead : kMenuRow;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(0, y, 0, h)]];
        y += h;
        if (!i.separatorItem) {
            NSString *keys = KeyGlyphs(i);
            CGFloat tw = ceil([i.title sizeWithAttributes:ta].width) + (keys.length ? ceil([keys sizeWithAttributes:ka].width) + 28 : 0) + (i.submenu ? 22 : 0);
            w = MAX(w, tw);
        }
    }
    self.items = items; self.rects = rects; self.gutter = gutter;
    CGFloat width = MIN(420, MAX(gutter ? 232 : 210, w + (gutter ? 40 : 18) + 22));
    NSMutableArray *full = [NSMutableArray array];
    for (NSValue *v in rects) { NSRect r = v.rectValue; r.origin.x = kMenuPad; r.size.width = width - kMenuPad * 2; [full addObject:[NSValue valueWithRect:r]]; }
    self.rects = full;
    [self setFrameSize:NSMakeSize(width, y + kMenuPad)];
    return width;
}

- (void)drawRect:(NSRect)dirty {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSUInteger k = 0; k < self.items.count; k++) {
        NSMenuItem *i = self.items[k]; NSRect r = self.rects[k].rectValue;
        if (!NSIntersectsRect(r, dirty)) continue;
        if (i.separatorItem) { [vSep setFill]; NSRectFill(NSMakeRect(NSMinX(r) + 8, round(NSMidY(r)), NSWidth(r) - 16, 1)); continue; }
        if (MenuItemIsHeader(i)) {
            [i.title drawInRect:NSMakeRect(NSMinX(r) + 8, NSMinY(r) + 6, NSWidth(r) - 16, 15)
                 withAttributes:@{NSFontAttributeName: UIFont(11, NSFontWeightMedium), NSForegroundColorAttributeName: vFaint, NSParagraphStyleAttributeName: ps}];
            continue;
        }
        BOOL on = MenuItemEnabled(i), hot = on && (NSInteger)k == self.hover;
        if (hot) RoundRect(r, 7, [vText colorWithAlphaComponent:ThemeIsLight() ? 0.07 : 0.09]);
        CGFloat tx = NSMinX(r) + (self.gutter ? 32 : 10);
        if (self.gutter) {
            NSRect g = NSMakeRect(NSMinX(r) + 6, NSMinY(r), 20, NSHeight(r));
            NSImage *ic = nil;
            if (i.state == NSControlStateValueOn) ic = Tinted(Symbol(@"checkmark", 11, NSFontWeightSemibold), on ? vText : vFaint);
            else if (i.image && !i.image.isTemplate) { DrawImage(i.image, CenterIn(NSMakeSize(16, 16), g)); }
            else if (i.image) ic = Tinted(i.image, on ? vDim : vFaint);
            else if (MenuSymbolFor(i.title)) ic = Tinted(Symbol(MenuSymbolFor(i.title), 12.5, NSFontWeightRegular), on ? vDim : vFaint);
            if (ic) DrawImage(ic, CenterIn(NSMakeSize(MIN(ic.size.width, 18), MIN(ic.size.height, 18)), g));
        }
        CGFloat right = NSMaxX(r) - 10;
        if (i.submenu) {
            NSImage *ch = Tinted(Symbol(@"chevron.right", 9.5, NSFontWeightSemibold), vFaint);
            DrawImage(ch, CenterIn(ch.size, NSMakeRect(right - 10, NSMinY(r), 10, NSHeight(r))));
            right -= 18;
        } else {
            NSString *keys = KeyGlyphs(i);
            if (keys.length) {
                NSDictionary *ka = @{NSFontAttributeName: UIFont(12, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint};
                NSSize ks = [keys sizeWithAttributes:ka];
                [keys drawAtPoint:NSMakePoint(right - ks.width, NSMinY(r) + round((NSHeight(r) - ks.height) / 2)) withAttributes:ka];
                right -= ks.width + 14;
            }
        }
        NSDictionary *ta = @{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: on ? vText : vFaint, NSParagraphStyleAttributeName: ps};
        CGFloat th = 17;
        [i.title drawInRect:NSMakeRect(tx, NSMinY(r) + round((NSHeight(r) - th) / 2), right - tx, th) withAttributes:ta];
    }
    // while something is dragged over the menu: where it lands
    if (self.dropInto >= 0 && self.dropInto < (NSInteger)self.rects.count) ShardStroke(self.rects[(NSUInteger)self.dropInto].rectValue, 7, vAccent, 1.5);
    else if (self.dropRow >= 0 && self.rects.count) {
        NSRect r = self.dropRow < (NSInteger)self.rects.count ? self.rects[(NSUInteger)self.dropRow].rectValue : self.rects.lastObject.rectValue;
        CGFloat y = self.dropRow < (NSInteger)self.rects.count ? NSMinY(r) : NSMaxY(r);
        RoundRect(NSMakeRect(NSMinX(r) + 6, y - 1, NSWidth(r) - 12, 2), 1, vAccent);
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas.copy) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (NSInteger)rowAt:(NSPoint)p {
    for (NSUInteger k = 0; k < self.rects.count; k++) if (NSPointInRect(p, self.rects[k].rectValue)) return (NSInteger)k;
    return -1;
}
- (BOOL)selectable:(NSInteger)k { return k >= 0 && k < (NSInteger)self.items.count && !self.items[(NSUInteger)k].separatorItem && !MenuItemIsHeader(self.items[(NSUInteger)k]) && MenuItemEnabled(self.items[(NSUInteger)k]); }
- (void)setHot:(NSInteger)k openSub:(BOOL)open {
    if (![self selectable:k]) k = -1;
    if (k != self.hover) { self.hover = k; self.needsDisplay = YES; }
    [self.subTimer invalidate]; self.subTimer = nil;
    VMenuPanel *p = self.panel;
    if (p.child && p.child.parentRow != k) CloseMenusFrom(p.child);
    if (k >= 0 && self.items[(NSUInteger)k].submenu && !p.child) {
        if (open) [self openSubmenu:k];
        else { __weak VMenuView *ws = self; self.subTimer = [NSTimer scheduledTimerWithTimeInterval:0.14 repeats:NO block:^(NSTimer *t) { if (ws.hover == k) [ws openSubmenu:k]; }]; }
    }
}
- (void)openSubmenu:(NSInteger)k {
    VMenuPanel *p = self.panel; if (p.child) return;
    NSRect r = self.rects[(NSUInteger)k].rectValue;
    NSRect sr = [p convertRectToScreen:[self convertRect:r toView:nil]];
    OpenMenuPanel(self.items[(NSUInteger)k].submenu, NSMakePoint(NSMaxX(p.frame) - 4, NSMaxY(sr) + kMenuPad), p.owner, p, NSMinX(p.frame) + 4);
    p.child.parentRow = k;
}
- (void)mouseMoved:(NSEvent *)e { [self setHot:[self rowAt:[self convertPoint:e.locationInWindow fromView:nil]] openSub:NO]; }
- (void)mouseEntered:(NSEvent *)e { [self mouseMoved:e]; }
- (void)mouseExited:(NSEvent *)e { if (!self.panel.child) { self.hover = -1; self.needsDisplay = YES; } }
- (void)mouseDown:(NSEvent *)e { self.pressAt = [self convertPoint:e.locationInWindow fromView:nil]; self.pressRow = [self rowAt:self.pressAt]; }
- (void)mouseDragged:(NSEvent *)e {
    id<VMenuDropTarget> t = MenuDropTarget(self.source);
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (!t || ![self selectable:self.pressRow] || hypot(p.x - self.pressAt.x, p.y - self.pressAt.y) < 4) return;
    NSMenuItem *it = self.items[(NSUInteger)self.pressRow];
    if (![t itemIsDraggable:it]) return;
    self.pressRow = -1;
    [self.subTimer invalidate];
    [t menu:self.source beginDragFor:it event:e view:self];
}
- (void)rightMouseDown:(NSEvent *)e {
    id<VMenuDropTarget> t = MenuDropTarget(self.source);
    NSInteger k = [self rowAt:[self convertPoint:e.locationInWindow fromView:nil]];
    NSMenu *ctx = t && [self selectable:k] ? [t menu:self.source contextMenuFor:self.items[(NSUInteger)k]] : nil;
    if (!ctx) return;
    NSWindow *owner = self.panel.owner; NSPoint s = NSEvent.mouseLocation;
    CloseMenus();
    OpenMenuPanel(ctx, s, owner, nil, 0);
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c {
    return c == NSDraggingContextWithinApplication ? NSDragOperationMove | NSDragOperationCopy : NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op {
    if (op != NSDragOperationNone) CloseMenus();   // moved somewhere else: the open menus are out of date
}
// Drops: before/after the nearest item, or into a folder (the middle of its row; its submenu opens to go deeper).
- (void)dropTargetAt:(NSPoint)p {
    self.dropRow = -1; self.dropInto = -1;
    NSInteger k = [self rowAt:p];
    if (k < 0) { self.dropRow = p.y < kMenuPad + 2 ? 0 : (NSInteger)self.rects.count; return; }
    NSMenuItem *it = self.items[(NSUInteger)k]; NSRect r = self.rects[(NSUInteger)k].rectValue;
    if (it.submenu && fabs(p.y - NSMidY(r)) < NSHeight(r) * 0.25) { self.dropInto = k; [self setHot:k openSub:NO]; return; }
    self.dropRow = p.y < NSMidY(r) ? k : k + 1;
}
- (NSMenuItem *)itemAtRow:(NSInteger)k { return k >= 0 && k < (NSInteger)self.items.count ? self.items[(NSUInteger)k] : nil; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    id<VMenuDropTarget> t = MenuDropTarget(self.source); if (!t) return NSDragOperationNone;
    [self dropTargetAt:[self convertPoint:info.draggingLocation fromView:nil]];
    NSDragOperation op = [t menu:self.source validateDrop:info before:[self itemAtRow:self.dropRow] into:[self itemAtRow:self.dropInto]];
    if (op == NSDragOperationNone) { self.dropRow = self.dropInto = -1; }
    self.needsDisplay = YES;
    return op;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [self draggingUpdated:info]; }
- (void)draggingExited:(id<NSDraggingInfo>)info { self.dropRow = self.dropInto = -1; self.needsDisplay = YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    id<VMenuDropTarget> t = MenuDropTarget(self.source);
    NSMenuItem *before = [self itemAtRow:self.dropRow], *into = [self itemAtRow:self.dropInto];
    BOOL any = self.dropRow >= 0 || self.dropInto >= 0;
    self.dropRow = self.dropInto = -1; self.needsDisplay = YES;
    BOOL ok = t && any && [t menu:self.source acceptDrop:info before:before into:into];
    if (ok) dispatch_async(dispatch_get_main_queue(), ^{ CloseMenus(); });
    return ok;
}
- (void)mouseUp:(NSEvent *)e {
    NSInteger k = [self rowAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (![self selectable:k]) return;
    if (self.items[(NSUInteger)k].submenu) { [self setHot:k openSub:YES]; return; }
    [self perform:self.items[(NSUInteger)k]];
}
- (void)perform:(NSMenuItem *)i {
    NSWindow *w = gMenus.firstObject.owner;
    CloseMenus();
    if (!i.action) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (w && !w.isKeyWindow && w.isVisible) [w makeKeyWindow];
        [NSApp sendAction:i.action to:i.target from:i];
    });
}
// keyboard, routed here by the menu's event monitor
- (BOOL)key:(NSEvent *)e {
    NSString *c = e.charactersIgnoringModifiers; if (!c.length) return NO;
    unichar ch = [c characterAtIndex:0];
    NSInteger n = (NSInteger)self.items.count;
    if (ch == NSDownArrowFunctionKey || ch == NSUpArrowFunctionKey) {
        NSInteger d = ch == NSDownArrowFunctionKey ? 1 : -1, k = self.hover;
        for (NSInteger s = 0; s < n; s++) { k = (k + d + n) % n; if (k < 0) k = n - 1; if ([self selectable:k]) break; }
        [self setHot:k openSub:NO]; return YES;
    }
    BOOL sub = self.hover >= 0 && self.items[(NSUInteger)self.hover].submenu;
    if ((ch == NSRightArrowFunctionKey || ch == '\r' || ch == 3 || ch == ' ') && sub) {   // into the submenu, first item lit
        [self setHot:self.hover openSub:YES];
        VMenuView *cl = self.panel.child.list; for (NSInteger k = 0; k < (NSInteger)cl.items.count; k++) if ([cl selectable:k]) { [cl setHot:k openSub:NO]; break; }
        return YES;
    }
    if (ch == '\r' || ch == 3 || ch == ' ') { if (self.hover >= 0) [self perform:self.items[(NSUInteger)self.hover]]; return YES; }
    if (ch == NSRightArrowFunctionKey || ch == NSLeftArrowFunctionKey) return YES;
    // a letter jumps to the next item that starts with it
    NSString *l = c.lowercaseString;
    for (NSInteger s = 1; s <= n; s++) {
        NSInteger k = (self.hover + s + n) % n;
        if ([self selectable:k] && [self.items[(NSUInteger)k].title.lowercaseString hasPrefix:l]) { [self setHot:k openSub:NO]; return YES; }
    }
    return YES;
}
@end

static void CloseMenusFrom(VMenuPanel *c) {
    NSUInteger i = [gMenus indexOfObject:c]; if (i == NSNotFound) return;
    NSArray *drop = [gMenus subarrayWithRange:NSMakeRange(i, gMenus.count - i)];
    for (VMenuPanel *x in drop) { [x.list.subTimer invalidate]; [x orderOut:nil]; }
    c.parentMenu.child = nil;
    [gMenus removeObjectsInArray:drop];
}
static void CloseMenus(void) {
    NSArray *open = gMenus.copy; [gMenus removeAllObjects];
    for (VMenuPanel *p in open.reverseObjectEnumerator) {
        [p.list.subTimer invalidate];
        [p orderOut:nil];
        id<NSMenuDelegate> d = p.list.source.delegate;
        if ([d respondsToSelector:@selector(menuDidClose:)]) [d menuDidClose:p.list.source];
    }
    if (gMenuLocal) { [NSEvent removeMonitor:gMenuLocal]; gMenuLocal = nil; }
    if (gMenuGlobal) { [NSEvent removeMonitor:gMenuGlobal]; gMenuGlobal = nil; }
    if (gMenuResign) { [NSNotificationCenter.defaultCenter removeObserver:gMenuResign]; gMenuResign = nil; }
}

static void WatchMenus(void) {
    if (gMenuLocal) return;
    gMenuLocal = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskKeyDown | NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *e) {
        if (!gMenus.count) return e;
        if (e.type == NSEventTypeKeyDown) {
            if (e.modifierFlags & NSEventModifierFlagCommand) { CloseMenus(); return e; }
            unichar ch = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
            VMenuPanel *top = gMenus.lastObject;
            if (ch == 0x1b) { if (top.parentMenu) CloseMenusFrom(top); else CloseMenus(); return nil; }
            if (ch == NSLeftArrowFunctionKey && top.parentMenu) { CloseMenusFrom(top); return nil; }
            [top.list key:e];
            return nil;
        }
        if (e.type == NSEventTypeScrollWheel) return [gMenus containsObject:(VMenuPanel *)e.window] ? e : nil;
        if ([gMenus containsObject:(VMenuPanel *)e.window]) return e;
        CloseMenus();
        return nil;   // the click that dismisses a menu does nothing else, like macOS menus
    }];
    gMenuGlobal = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^(NSEvent *e) { CloseMenus(); }];
    gMenuResign = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { CloseMenus(); }];
}

// topLeft is in screen coordinates. flipX: where a submenu goes if there's no room on the right.
static void OpenMenuPanel(NSMenu *m, NSPoint topLeft, NSWindow *owner, VMenuPanel *parent, CGFloat flipX) {
    if (!m) return;
    if ([m.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [m.delegate menuNeedsUpdate:m];
    if ([m.delegate respondsToSelector:@selector(menuWillOpen:)]) [m.delegate menuWillOpen:m];
    if (!gMenus) gMenus = [NSMutableArray array];
    VMenuView *list = [[VMenuView alloc] initWithFrame:NSZeroRect];
    list.source = m; list.hover = -1; list.pressRow = list.dropRow = list.dropInto = -1;
    if (MenuDropTarget(m)) [list registerForDraggedTypes:@[@"com.flint.bookmark-index", NSPasteboardTypeURL, @"WebURLsWithTitlesPboardType", NSPasteboardTypeString]];
    CGFloat w = [list buildRows], h = NSHeight(list.frame);
    if (!list.items.count) return;
    NSScreen *scr = owner.screen ?: NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSPointInRect(topLeft, NSInsetRect(s.frame, -1, -1))) scr = s;
    NSRect vis = NSInsetRect(scr.visibleFrame, 6, 6);
    CGFloat ph = MIN(h, NSHeight(vis));
    NSRect f = NSMakeRect(topLeft.x, topLeft.y - ph, w, ph);
    if (NSMaxX(f) > NSMaxX(vis)) f.origin.x = parent ? flipX - w : NSMaxX(vis) - w;
    if (NSMinX(f) < NSMinX(vis)) f.origin.x = NSMinX(vis);
    if (NSMinY(f) < NSMinY(vis)) f.origin.y = parent ? NSMinY(vis) : MIN(topLeft.y + 4, NSMaxY(vis) - ph);   // no room below: open upwards
    if (NSMaxY(f) > NSMaxY(vis)) f.origin.y = NSMaxY(vis) - ph;

    VMenuPanel *p = [[VMenuPanel alloc] initWithContentRect:f styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    p.opaque = NO; p.backgroundColor = NSColor.clearColor; p.hasShadow = YES; p.level = NSPopUpMenuWindowLevel;
    p.releasedWhenClosed = NO; p.hidesOnDeactivate = YES; p.appearance = ThemeAppearance(); p.becomesKeyOnlyIfNeeded = YES;
    p.owner = owner; p.parentMenu = parent; p.list = list; list.panel = p;
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, ph)];
    root.wantsLayer = YES;
    root.layer.backgroundColor = vCard.CGColor; root.layer.cornerRadius = 12; root.layer.masksToBounds = YES;
    if (@available(macOS 11.0, *)) root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.borderWidth = 1; root.layer.borderColor = (ThemeIsLight() ? [NSColor colorWithWhite:0 alpha:0.1] : [NSColor colorWithWhite:1 alpha:0.09]).CGColor;
    if (h > ph) {   // taller than the screen: it scrolls
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:root.bounds];
        sv.drawsBackground = NO; sv.hasVerticalScroller = YES; sv.scrollerStyle = NSScrollerStyleOverlay; sv.autohidesScrollers = YES;
        sv.documentView = list; [root addSubview:sv];
    } else [root addSubview:list];
    p.contentView = root;
    if (parent) parent.child = p;
    [gMenus addObject:p];
    WatchMenus();
    p.alphaValue = 0;
    [p orderFront:nil];
    [p invalidateShadow];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.09; p.animator.alphaValue = 1; }];
}

// Same contract as -[NSMenu popUpMenuPositioningItem:nil atLocation:inView:]: the menu's top-left corner
// goes at `p` in the view's coordinates.
static void PopMenu(NSMenu *m, NSPoint p, NSView *v) {
    if (!m || !v.window) return;
    CloseMenus();
    NSPoint s = [v.window convertPointToScreen:[v convertPoint:p toView:nil]];
    OpenMenuPanel(m, s, v.window, nil, 0);
}
// A menu whose top-right corner sits at `p` (for buttons at the right end of the toolbar).
static void PopMenuRight(NSMenu *m, NSPoint p, NSView *v) {
    if (!m || !v.window) return;
    CloseMenus();
    VMenuView *probe = [[VMenuView alloc] initWithFrame:NSZeroRect]; probe.source = m;
    if ([m.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [m.delegate menuNeedsUpdate:m];
    CGFloat w = [probe buildRows];
    NSPoint s = [v.window convertPointToScreen:[v convertPoint:p toView:nil]];
    OpenMenuPanel(m, NSMakePoint(s.x - w, s.y), v.window, nil, 0);
}
// Right-click menus: at the pointer.
static void PopMenuForEvent(NSMenu *m, NSEvent *e, NSView *v) {
    if (!m || !v.window) return;
    PopMenu(m, [v convertPoint:e.locationInWindow fromView:nil], v);
}
#pragma mark - Dragging pages and bookmarks

static NSString *const kBookmarkDragType = @"com.flint.bookmark-index";   // a bookmark being moved on the bar

// What a dragged page looks like under the pointer: its icon and title in a small pill.
static NSImage *DragChip(NSString *title, NSImage *icon) {
    NSDictionary *a = @{NSFontAttributeName: UIFont(12.5, NSFontWeightMedium), NSForegroundColorAttributeName: vText};
    if (title.length > 40) title = [[title substringToIndex:39] stringByAppendingString:@"…"];
    CGFloat w = ceil([title sizeWithAttributes:a].width) + 40, h = 28;
    return [NSImage imageWithSize:NSMakeSize(w, h) flipped:YES drawingHandler:^BOOL(NSRect r) {
        RoundRect(r, 8, [vPill colorWithAlphaComponent:0.96]);
        NSImage *im = icon ?: Tinted(Symbol(@"globe", 13, NSFontWeightRegular), vDim);
        DrawImage(im, NSMakeRect(8, 6, 16, 16));
        [title drawAtPoint:NSMakePoint(30, 6) withAttributes:a];
        return YES;
    }];
}
// Start dragging a page's address: the bookmarks bar, other apps, the Finder (a .webloc) and text fields all take it.
static void BeginURLDrag(NSView<NSDraggingSource> *v, NSEvent *e, NSString *url, NSString *title, NSImage *icon, NSString *bookmarkIndex) {
    NSPasteboardItem *it = [NSPasteboardItem new];
    if (url.length) { [it setString:url forType:NSPasteboardTypeURL]; [it setString:url forType:NSPasteboardTypeString]; }
    if (title.length) [it setString:title forType:@"public.url-name"];
    if (bookmarkIndex) [it setString:bookmarkIndex forType:kBookmarkDragType];
    NSDraggingItem *di = [[NSDraggingItem alloc] initWithPasteboardWriter:it];
    NSImage *img = DragChip(title.length ? title : url, icon);
    NSPoint p = [v convertPoint:e.locationInWindow fromView:nil];
    [di setDraggingFrame:NSMakeRect(p.x - 14, p.y - img.size.height / 2, img.size.width, img.size.height) contents:img];
    [v beginDraggingSessionWithItems:@[di] event:e source:v];
}

#pragma mark - Buttons

@implementation VButton
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c { return NSDragOperationCopy | NSDragOperationLink; }
// The site button: a click opens site information; a drag carries the page.
- (void)mouseDown:(NSEvent *)e {
    VTab *t = self.dragsPage ? WinFor(self).current : nil;
    if (!t || t.isHome || !t.url.length || [t.url hasPrefix:@"flint:"]) { [super mouseDown:e]; return; }
    self.highlighted = YES;
    NSPoint start = e.locationInWindow;
    while (YES) {
        NSEvent *n = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
        if (n.type == NSEventTypeLeftMouseUp) {
            self.highlighted = NO;
            if (NSPointInRect([self convertPoint:n.locationInWindow fromView:nil], self.bounds)) [self sendAction:self.action to:self.target];
            return;
        }
        if (hypot(n.locationInWindow.x - start.x, n.locationInWindow.y - start.y) > 4) {
            self.highlighted = NO;
            BeginURLDrag(self, e, t.url, t.title, t.favicon, nil);
            return;
        }
    }
}

+ (instancetype)symbol:(NSString *)s size:(CGFloat)pt tip:(NSString *)tip target:(id)t action:(SEL)a {
    VButton *b = [[VButton alloc] initWithFrame:NSMakeRect(0, 0, 30, 28)];
    b.symbolName = s; b.symbolSize = pt;
    b.bordered = NO; b.title = @""; b.toolTip = tip; b.target = t; b.action = a;
    b.focusRingType = NSFocusRingTypeNone;
    [b setButtonType:NSButtonTypeMomentaryChange];
    return b;
}
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas.copy) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)e { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)e { self.hovered = NO; self.needsDisplay = YES; }
- (void)setActive:(BOOL)a { _active = a; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)r {
    BOOL on = self.enabled;
    if (on && (self.hovered || self.isHighlighted)) RoundRect(NSInsetRect(self.bounds, 1, 2), 7, self.isHighlighted ? vActive : vHover);
    NSColor *c = !on ? [vDim colorWithAlphaComponent:0.3] : self.active ? vAccent : (self.hovered ? vText : vDim);
    NSImage *im = Tinted(Symbol(self.symbolName, self.symbolSize ?: 14, NSFontWeightMedium), c);
    if (im) DrawImage(im, CenterIn(im.size, self.bounds));
}
@end

#pragma mark - Address bar

@interface VAddressField : NSTextField
@property (copy) void (^onFocus)(void);
@end
@implementation VAddressField
- (BOOL)becomeFirstResponder {
    BOOL ok = [super becomeFirstResponder];
    if (ok && self.onFocus) self.onFocus();
    return ok;
}
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)rightMouseDown:(NSEvent *)e {   // not typing: Flint's own menu for the page's address
    if (self.currentEditor) { [super rightMouseDown:e]; return; }
    PopMenuForEvent([self menuForEvent:e], e, self);
}

// While typing: the field editor's menu, plus Paste and Go
- (NSMenu *)textView:(NSTextView *)tv menu:(NSMenu *)menu forEvent:(NSEvent *)e atIndex:(NSUInteger)i {
    NSString *clip = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (clip.length) {
        NSInteger at = 0;
        for (NSInteger k = 0; k < menu.numberOfItems; k++) if ([menu itemAtIndex:k].action == @selector(paste:)) { at = k + 1; break; }
        NSString *t = URLFromInput(clip) && [clip rangeOfString:@" "].location == NSNotFound && [clip containsString:@"."] ? @"Paste and Go" : @"Paste and Search";
        NSMenuItem *pg = [[NSMenuItem alloc] initWithTitle:t action:@selector(pasteAndGo:) keyEquivalent:@""]; pg.target = self;
        [menu insertItem:pg atIndex:at];
    }
    return menu;
}
// Not typing: the page's address
- (NSMenu *)menuForEvent:(NSEvent *)e {
    if (self.currentEditor) return [super menuForEvent:e];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    VTab *t = WinFor(self).current;
    if (t.url && !t.isHome) {
        NSMenuItem *c = [m addItemWithTitle:@"Copy Link" action:@selector(copyText:) keyEquivalent:@""]; c.target = WinFor(self); c.representedObject = t.url;
        NSURL *clean = StripTracking([NSURL URLWithString:t.url]);
        if (clean) { NSMenuItem *cc = [m addItemWithTitle:@"Copy Clean Link" action:@selector(copyText:) keyEquivalent:@""]; cc.target = WinFor(self); cc.representedObject = clean.absoluteString; }
    }
    if ([NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString].length) { NSMenuItem *pg = [m addItemWithTitle:@"Paste and Go" action:@selector(pasteAndGo:) keyEquivalent:@""]; pg.target = self; }
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *ed = [m addItemWithTitle:@"Edit Address" action:@selector(focusAddress) keyEquivalent:@""]; ed.target = WinFor(self);
    return m;
}
- (void)pasteAndGo:(id)s {
    NSString *clip = Trim([NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"");
    if (clip.length) { [self.window makeFirstResponder:nil]; [WinFor(self) go:clip]; }
}
@end

// progress ring around the downloads button
@interface VRing : NSView
@property double value;   // 0…1, or <0 for none
@end
@implementation VRing
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)r {
    if (self.value < 0) return;
    NSRect b = NSInsetRect(self.bounds, (NSWidth(self.bounds) - 22) / 2, (NSHeight(self.bounds) - 22) / 2);
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:b]; track.lineWidth = 2; [[vLine colorWithAlphaComponent:0.9] setStroke]; [track stroke];
    NSBezierPath *arc = [NSBezierPath bezierPath]; arc.lineWidth = 2; arc.lineCapStyle = NSLineCapStyleRound;
    [arc appendBezierPathWithArcWithCenter:NSMakePoint(NSMidX(b), NSMidY(b)) radius:NSWidth(b) / 2 startAngle:90 endAngle:90 - 360 * MAX(0.03, MIN(1, self.value)) clockwise:YES];
    [vAccent setStroke]; [arc stroke];
}
@end

// A newer build waiting to be switched to (development): the "Update" pill at the far right.
static BOOL gUpdateReady, gUpdating;
static NSString *gUpdateNotes;
@interface VPillButton : NSButton
@end
@implementation VPillButton
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)drawRect:(NSRect)dirty {
    NSRect r = NSInsetRect(self.bounds, 0.5, 3.5);
    BOOL down = self.cell.isHighlighted;
    NSColor *fill = gUpdating ? [vText colorWithAlphaComponent:0.25] : [vText colorWithAlphaComponent:down ? 0.75 : 0.92];
    RoundRect(r, NSHeight(r) / 2, fill);
    NSDictionary *a = @{NSFontAttributeName: UIFont(11.5, NSFontWeightSemibold), NSForegroundColorAttributeName: gUpdating ? vText : vBg};
    NSString *t = gUpdating ? @"Updating…" : @"Update";
    NSSize s = [t sizeWithAttributes:a];
    [t drawAtPoint:NSMakePoint(round(NSMidX(r) - s.width / 2), round(NSMidY(r) - s.height / 2)) withAttributes:a];
}
@end

// The profile badge's click target (the toolbar draws the badge itself).
@interface VBadgeButton : NSButton
@end
@implementation VBadgeButton
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)drawRect:(NSRect)r {}
@end

@interface VToolbar : NSView
@property (strong) VButton *sideBtn, *backBtn, *fwdBtn, *reloadBtn, *infoBtn, *starBtn, *shieldBtn, *menuBtn, *dlBtn;
@property (strong) VButton *homeBtn, *addTabBtn, *readerBtn, *shareBtn, *extMenuBtn, *pipBtn;
- (void)placePillButtons;
@property (strong) VPillButton *updateBtn;
@property (strong) VRing *dlRing;
@property (strong) VAddressField *field;
@property NSRect pill;
@property double progress;
@property BOOL editing;
@property NSInteger blocked;
@property CGFloat leftInset;
@property (strong) NSMutableArray<NSButton *> *extBtns;
@property NSRect privateBadge, profileRect;
@property (strong) VBadgeButton *profileBtn;
- (void)layoutBar;
- (NSView *)extensionButtonFor:(NSString *)ident;
@end

@interface VExtPanel : NSView
@property (weak) VToolbar *bar;
@property (weak) NSPopover *popover;
@property (strong) NSArray<NSString *> *ids;
@property NSInteger hover;
- (instancetype)initWithBar:(VToolbar *)bar;
@end

@implementation VToolbar
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) return nil;
    VWindow *w = WinFor(self);
    self.sideBtn = [VButton symbol:@"sidebar.left" size:14 tip:@"Toggle sidebar (⌘S)" target:w action:@selector(toggleSidebar:)];
    self.backBtn = [VButton symbol:@"chevron.left" size:14 tip:@"Back (⌘[)" target:w action:@selector(goBack:)];
    self.fwdBtn = [VButton symbol:@"chevron.right" size:14 tip:@"Forward (⌘])" target:w action:@selector(goForward:)];
    self.reloadBtn = [VButton symbol:@"arrow.clockwise" size:13 tip:@"Reload (⌘R)" target:w action:@selector(reloadOrStop:)];
    self.infoBtn = [VButton symbol:@"lock.fill" size:11 tip:@"Site information · drag to bookmark the page" target:w action:@selector(siteMenu:)];
    self.infoBtn.dragsPage = YES;
    self.starBtn = [VButton symbol:@"star" size:13 tip:@"Bookmark this page (⌘D)" target:w action:@selector(toggleBookmark:)];
    self.shieldBtn = [VButton symbol:@"checkmark.shield" size:14 tip:@"Ads and trackers" target:w action:@selector(shieldMenu:)];
    self.menuBtn = [VButton symbol:@"ellipsis" size:14 tip:@"Menu" target:w action:@selector(mainMenu:)];
    self.dlBtn = [VButton symbol:@"tray.and.arrow.down" size:13.5 tip:@"Downloads (⌥⌘L)" target:w action:@selector(showDownloads:)];
    self.homeBtn = [VButton symbol:@"house" size:13 tip:@"Home" target:w action:@selector(goHome:)];
    self.addTabBtn = [VButton symbol:@"plus" size:14 tip:@"New tab (⌘T)" target:w action:@selector(newTabAction:)];
    self.readerBtn = [VButton symbol:@"doc.plaintext" size:13 tip:@"Reader (⌃⌘R)" target:w action:@selector(toggleReader:)];
    self.shareBtn = [VButton symbol:@"square.and.arrow.up" size:13 tip:@"Share" target:w action:@selector(sharePage:)];
    self.extMenuBtn = [VButton symbol:@"puzzlepiece.extension" size:13 tip:@"Extensions" target:self action:@selector(extensionsMenu:)];
    for (NSView *v in @[self.homeBtn, self.addTabBtn, self.readerBtn, self.shareBtn, self.extMenuBtn]) [self addSubview:v];
    self.dlRing = [[VRing alloc] initWithFrame:NSMakeRect(0, 0, 30, 28)]; self.dlRing.value = -1;
    self.dlRing.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.dlBtn addSubview:self.dlRing]; [self addSubview:self.dlBtn];
    __weak VToolbar *weakBar = self;
    [NSNotificationCenter.defaultCenter addObserverForName:@"FlintDownloadsChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [weakBar updateDownloads]; }];
    for (NSView *v in @[self.sideBtn, self.backBtn, self.fwdBtn, self.reloadBtn, self.shieldBtn, self.menuBtn]) [self addSubview:v];
    self.updateBtn = [[VPillButton alloc] initWithFrame:NSZeroRect];
    self.updateBtn.bordered = NO; self.updateBtn.title = @""; self.updateBtn.target = nil; self.updateBtn.action = @selector(installUpdate:);
    self.updateBtn.hidden = YES; [self addSubview:self.updateBtn];
    self.profileBtn = [[VBadgeButton alloc] initWithFrame:NSZeroRect];
    self.profileBtn.bordered = NO; self.profileBtn.title = @""; self.profileBtn.target = nil; self.profileBtn.action = @selector(profileMenu:);
    self.profileBtn.toolTip = @"Profiles"; self.profileBtn.hidden = YES; [self addSubview:self.profileBtn];
    VAddressField *f = [[VAddressField alloc] initWithFrame:NSZeroRect];
    f.bezeled = NO; f.bordered = NO; f.drawsBackground = NO; f.focusRingType = NSFocusRingTypeNone;
    f.font = UIFont(13, NSFontWeightRegular); f.textColor = vText;
    f.cell.usesSingleLineMode = YES; f.cell.scrollable = YES; f.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    f.alignment = NSTextAlignmentCenter;
    f.placeholderAttributedString = [[NSAttributedString alloc] initWithString:w.isPrivate ? @"Search privately or enter address" : @"Search or enter address"
        attributes:@{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint}];
    f.delegate = w;
    self.field = f;
    __weak VToolbar *ws = self;
    f.onFocus = ^{
        VWindow *w = WinFor(ws);
        [w refreshChrome];
        VTab *ct = w.current;   // editing shows the whole address, left-aligned, ready to copy or change
        NSString *full = (ct.url && !ct.isHome && ![ct.url hasPrefix:@"flint://reader"]) ? ct.url : @"";
        NSMutableParagraphStyle *lp = [NSMutableParagraphStyle new]; lp.alignment = NSTextAlignmentLeft; lp.lineBreakMode = NSLineBreakByClipping;
        NSDictionary *ta = @{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: vText, NSParagraphStyleAttributeName: lp};
        ws.field.alignment = NSTextAlignmentLeft;
        ws.field.attributedStringValue = [[NSAttributedString alloc] initWithString:full attributes:ta];
        ws.editing = YES; ws.needsDisplay = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTextView *ed = (NSTextView *)ws.field.currentEditor;
            if ([ed isKindOfClass:NSTextView.class]) { ed.typingAttributes = ta; ed.alignment = NSTextAlignmentLeft; [ed selectAll:nil]; }
            ws.editing = ws.field.currentEditor != nil; ws.needsDisplay = YES;
        });
    };
    [self addSubview:f];
    [self addSubview:self.infoBtn]; [self addSubview:self.starBtn];
    self.pipBtn = [VButton symbol:@"pip.enter" size:13 tip:@"Picture in Picture (⌃⌘P)" target:w action:@selector(pictureInPicture:)];
    self.pipBtn.hidden = YES; [self addSubview:self.pipBtn];
    self.leftInset = 78;
    // one button per extension with a popup (Proton Pass…), Chrome-style, left of the shield
    self.extBtns = [NSMutableArray array];
    if (!w.isPrivate) for (id e in FExtHost.shared.extensions) {
        NSImage *icon = [FExtHost.shared iconFor:e]; if (!icon) continue;
        NSButton *b = [NSButton buttonWithImage:icon target:self action:@selector(extensionClicked:)];
        b.bordered = NO; b.imageScaling = NSImageScaleProportionallyDown; b.toolTip = [e valueForKey:@"name"];
        b.identifier = [e valueForKey:@"ident"];
        [self.extBtns addObject:b]; [self addSubview:b];
    }
    return self;
}
- (void)extensionClicked:(NSButton *)b {
    for (id e in FExtHost.shared.extensions) if ([[e valueForKey:@"ident"] isEqualToString:b.identifier]) [FExtHost.shared openPopup:e from:b];
}
- (void)updateDownloads {
    double p = VDownloads.shared.activeProgress;
    BOOL wasHidden = self.dlBtn.hidden;
    if (wasHidden != !(VDownloads.shared.worthShowing || ToolbarShows(@"dlalways"))) [self layoutBar];
    self.dlRing.value = p; self.dlRing.needsDisplay = YES;
    self.dlBtn.symbolName = p >= 0 ? @"arrow.down" : @"tray.and.arrow.down"; self.dlBtn.symbolSize = p >= 0 ? 10 : 13.5; self.dlBtn.needsDisplay = YES;
}
- (NSView *)extensionButtonFor:(NSString *)ident { for (NSButton *b in self.extBtns) if ([b.identifier isEqualToString:ident]) return b; return nil; }

- (void)layoutBar {
    CGFloat H = NSHeight(self.bounds), W = NSWidth(self.bounds), y = round((H - 28) / 2);
    CGFloat x = self.leftInset;
    NSDictionary *left = @{@"sidebar": self.sideBtn, @"back": self.backBtn, @"forward": self.fwdBtn, @"reload": self.reloadBtn, @"home": self.homeBtn};
    for (NSString *k in @[@"sidebar", @"back", @"forward", @"reload", @"home"]) {
        VButton *b = left[k]; b.hidden = !ToolbarShows(k);
        if (!b.hidden) { b.frame = NSMakeRect(x, y, 30, 28); x += 31; }
    }
    CGFloat right = W - 8;
    self.updateBtn.hidden = !gUpdateReady;
    if (gUpdateReady) {
        CGFloat pw = gUpdating ? 84 : 64;
        self.updateBtn.frame = NSMakeRect(right - pw, y, pw, 28); right -= pw + 6;
        self.updateBtn.toolTip = gUpdateNotes.length ? [@"A newer Flint is ready. What changed:\n" stringByAppendingString:gUpdateNotes] : @"A newer Flint is ready: click to switch to it (your tabs come back).";
        self.updateBtn.needsDisplay = YES;
    }
    self.menuBtn.frame = NSMakeRect(right - 30, y, 30, 28); right -= 32;
    // whose window this is: the profile's avatar beside ⋯ (where Chrome keeps it); with several profiles, its name too
    VWindow *ow = WinFor(self);
    if (ow && !ow.isPrivate) {
        NSString *nm = ProfileName(ow.profile);
        CGFloat pw = Profiles().count > 1 ? MIN(140, ceil([nm sizeWithAttributes:@{NSFontAttributeName: UIFont(11.5, NSFontWeightMedium)}].width) + 36) : 28;
        self.profileRect = NSMakeRect(right - pw, y + 2, pw, 24); right -= pw + 4;
        self.profileBtn.toolTip = [NSString stringWithFormat:@"%@ profile: click to switch or add one", nm];
    } else self.profileRect = NSZeroRect;
    self.profileBtn.frame = self.profileRect; self.profileBtn.hidden = NSIsEmptyRect(self.profileRect);
    self.shieldBtn.hidden = !ToolbarShows(@"shield");
    if (!self.shieldBtn.hidden) { self.shieldBtn.frame = NSMakeRect(right - 34, y, 34, 28); right -= 36; }
    for (VButton *b in @[self.addTabBtn, self.shareBtn, self.readerBtn]) {
        NSString *k = b == self.addTabBtn ? @"newtab" : b == self.shareBtn ? @"share" : @"reader";
        b.hidden = !ToolbarShows(k);
        if (!b.hidden) { b.frame = NSMakeRect(right - 30, y, 30, 28); right -= 31; }
    }
    self.dlBtn.hidden = !VDownloads.shared.worthShowing && !ToolbarShows(@"dlalways");
    if (!self.dlBtn.hidden) { self.dlBtn.frame = NSMakeRect(right - 30, y, 30, 28); self.dlRing.frame = self.dlBtn.bounds; right -= 31; }
    // extensions: the puzzle holds them all; pinned ones also get their own button beside it
    self.extMenuBtn.hidden = !self.extBtns.count || !ToolbarShows(@"extensions");
    if (!self.extMenuBtn.hidden) { self.extMenuBtn.frame = NSMakeRect(right - 30, y, 30, 28); right -= 31; }
    for (NSButton *b in self.extBtns.reverseObjectEnumerator) {
        b.hidden = !ExtensionPinned(b.identifier);
        if (!b.hidden) { b.frame = NSMakeRect(right - 30, y, 30, 28); right -= 31; }
    }
    right -= 4;
    x += 6;
    // private windows say so
    if (ow.isPrivate) {
        CGFloat bw = ceil([@"Private" sizeWithAttributes:@{NSFontAttributeName: UIFont(11.5, NSFontWeightMedium)}].width) + 36;
        self.privateBadge = NSMakeRect(x, y + 3, bw, 22); x += bw + 6;
    } else self.privateBadge = NSZeroRect;
    // the address bar: full width, or a centred medium/compact bar
    CGFloat avail = MAX(120, right - x);
    NSInteger mode = [Defaults() integerForKey:kAddrWidth];
    CGFloat want = mode == 2 ? 400 : mode == 1 ? 620 : avail;
    CGFloat pw = MIN(avail, want);
    CGFloat px = mode == 0 ? x : MAX(x, MIN(right - pw, round(W / 2 - pw / 2)));
    self.pill = NSMakeRect(px, y, pw, 28);
    self.infoBtn.frame = NSMakeRect(NSMinX(self.pill) + 3, y + 2, 24, 24);
    [self placePillButtons];
    self.needsDisplay = YES;
}
// the right end of the address bar: the star, and the picture-in-picture button when the page has a video
- (void)placePillButtons {
    CGFloat y = NSMinY(self.pill), r = NSMaxX(self.pill) - 3;
    if (!self.starBtn.hidden) { self.starBtn.frame = NSMakeRect(r - 24, y + 2, 24, 24); r -= 25; }
    if (!self.pipBtn.hidden) { self.pipBtn.frame = NSMakeRect(r - 24, y + 2, 24, 24); r -= 25; }
    CGFloat right = MAX(30, NSMaxX(self.pill) - r);
    self.field.frame = NSMakeRect(NSMinX(self.pill) + 30, y + 6, NSWidth(self.pill) - 30 - MAX(30, right + 3), 17);
}

#pragma mark Customising the toolbar (right-click it)

static void RelayoutToolbars(void) { for (VWindow *w in gWindows) { [w.toolbar layoutBar]; [w refreshChrome]; } }

- (void)rightMouseDown:(NSEvent *)e {
    NSMenu *m = [self menuForEvent:e];
    if (m) PopMenuForEvent(m, e, self); else [super rightMouseDown:e];
}

- (NSMenu *)menuForEvent:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (NSPointInRect(p, self.pill)) return nil;   // the address bar has its own menu
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSView *hit = [self hitTest:[self.superview convertPoint:e.locationInWindow fromView:nil]];
    while (hit && hit.superview != self) hit = hit.superview;
    if ([self.extBtns containsObject:(NSButton *)hit]) {
        NSString *ident = hit.identifier;
        NSMenuItem *h = [m addItemWithTitle:[FExtHost.shared nameForID:ident] ?: @"Extension" action:nil keyEquivalent:@""]; h.enabled = NO;
        if ([FExtHost.shared hasOptionsForID:ident]) { NSMenuItem *o = [m addItemWithTitle:@"Options" action:@selector(extensionOptions:) keyEquivalent:@""]; o.target = self; o.representedObject = ident; }
        NSMenuItem *u = [m addItemWithTitle:@"Unpin from Toolbar" action:@selector(togglePin:) keyEquivalent:@""]; u.target = self; u.representedObject = ident;
        NSMenuItem *mg = [m addItemWithTitle:@"Manage Extensions…" action:@selector(manageExtensions:) keyEquivalent:@""]; mg.target = self;
        [m addItem:NSMenuItem.separatorItem];
    }
    NSMenuItem *head = [m addItemWithTitle:@"Show in Toolbar" action:nil keyEquivalent:@""]; head.enabled = NO;
    NSArray *items = @[@[@"sidebar", @"Sidebar Button"], @[@"back", @"Back"], @[@"forward", @"Forward"], @[@"reload", @"Reload"], @[@"home", @"Home"],
                       @[@"star", @"Bookmark Star"], @[@"reader", @"Reader"], @[@"share", @"Share"], @[@"newtab", @"New Tab"],
                       @[@"dlalways", @"Downloads (always)"], @[@"extensions", @"Extensions Menu"], @[@"shield", @"Ad Blocking Shield"]];
    for (NSArray *it in items) {
        NSMenuItem *mi = [m addItemWithTitle:it[1] action:@selector(toggleShown:) keyEquivalent:@""];
        mi.target = self; mi.representedObject = it[0]; mi.state = ToolbarShows(it[0]) ? NSControlStateValueOn : NSControlStateValueOff;
        mi.indentationLevel = 1;
    }
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *wi = [m addItemWithTitle:@"Address Bar Width" action:nil keyEquivalent:@""];
    NSMenu *wm = [[NSMenu alloc] initWithTitle:@""];
    NSArray *widths = @[@"Full", @"Medium", @"Compact"];
    for (NSUInteger i = 0; i < widths.count; i++) {
        NSMenuItem *x = [wm addItemWithTitle:widths[i] action:@selector(setAddressWidth:) keyEquivalent:@""];
        x.target = self; x.tag = (NSInteger)i; x.state = [Defaults() integerForKey:kAddrWidth] == (NSInteger)i ? NSControlStateValueOn : NSControlStateValueOff;
    }
    wi.submenu = wm;
    NSMenuItem *bb = [m addItemWithTitle:[Defaults() boolForKey:kShowBookmarks] ? @"Hide Bookmarks Bar" : @"Show Bookmarks Bar" action:@selector(toggleBookmarksBar:) keyEquivalent:@""]; bb.target = WinFor(self);
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *rs = [m addItemWithTitle:@"Reset Toolbar" action:@selector(resetToolbar:) keyEquivalent:@""]; rs.target = self;
    NSMenuItem *more = [m addItemWithTitle:@"Customise in Settings…" action:@selector(showSettings:) keyEquivalent:@""]; more.target = gApp;
    return m;
}
- (void)toggleShown:(NSMenuItem *)i { SetToolbarShows(i.representedObject, !ToolbarShows(i.representedObject)); RelayoutToolbars(); }
- (void)setAddressWidth:(NSMenuItem *)i { [Defaults() setInteger:i.tag forKey:kAddrWidth]; RelayoutToolbars(); }
- (void)resetToolbar:(id)s {
    for (NSString *k in @[@"hiddenToolbarButtons", kShowExtra, kAddrWidth, kExtPinned]) [Defaults() removeObjectForKey:k];
    RelayoutToolbars();
}
- (void)manageExtensions:(id)s { [gApp performSelector:@selector(showSettingsSection:) withObject:@7]; }
- (void)togglePin:(NSMenuItem *)i {
    NSString *ident = i.representedObject;
    NSMutableArray *p = [[Defaults() arrayForKey:kExtPinned] ?: [self.extBtns valueForKey:@"identifier"] mutableCopy];
    if ([p containsObject:ident]) [p removeObject:ident]; else [p addObject:ident];
    [Defaults() setObject:p forKey:kExtPinned];
    RelayoutToolbars();
}
// The puzzle: a panel listing every extension. Click one to open it; the pin keeps it on the toolbar.
- (void)extensionsMenu:(VButton *)sender {
    NSPopover *p = [NSPopover new];
    VExtPanel *panel = [[VExtPanel alloc] initWithBar:self];
    NSViewController *vc = [NSViewController new]; vc.view = panel;
    p.contentViewController = vc; p.contentSize = panel.frame.size;
    p.behavior = NSPopoverBehaviorTransient; p.appearance = ThemeAppearance(); p.animates = YES;
    panel.popover = p;
    [p showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}
- (void)extensionOptions:(NSMenuItem *)i { [FExtHost.shared openOptionsForID:i.representedObject]; }
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self layoutBar]; }

- (void)drawRect:(NSRect)dirty {
    [vBg setFill]; NSRectFill(NSIntersectionRect(dirty, self.bounds));
    RoundRect(self.pill, 8, self.editing ? vPillFocus : vPill);
    if (self.editing) ShardStroke(self.pill, 8, vLine, 1);
    if (!NSIsEmptyRect(self.privateBadge)) {   // private windows say so, quietly
        RoundRect(self.privateBadge, 8, vPill);
        NSImage *eye = Tinted(Symbol(@"eye.slash", 10, NSFontWeightMedium), vDim);
        DrawImage(eye, CenterIn(eye.size, NSMakeRect(NSMinX(self.privateBadge) + 7, NSMinY(self.privateBadge), 16, NSHeight(self.privateBadge))));
        [@"Private" drawInRect:NSMakeRect(NSMinX(self.privateBadge) + 26, NSMinY(self.privateBadge) + 4, NSWidth(self.privateBadge) - 32, 16)
               withAttributes:@{NSFontAttributeName: UIFont(11.5, NSFontWeightMedium), NSForegroundColorAttributeName: vDim}];
    }
    if (!NSIsEmptyRect(self.profileRect)) {   // the profile: its avatar; with several profiles, a pill with its name and a hairline in its colour
        VWindow *ow = WinFor(self); NSRect r = self.profileRect; BOOL named = NSWidth(r) > 30; CGFloat a = 18;
        if (named) { RoundRect(r, 12, vPill); ShardStroke(r, 12, [ProfileColor(ow.profile) colorWithAlphaComponent:0.5], 1); }
        DrawImage(ProfileAvatar(ow.profile, ProfileName(ow.profile), a), NSMakeRect(named ? NSMinX(r) + 3 : round(NSMidX(r) - a / 2), round(NSMidY(r) - a / 2), a, a));
        if (named) {
            NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
            [ProfileName(ow.profile) drawInRect:NSMakeRect(NSMinX(r) + 26, NSMinY(r) + 5, NSWidth(r) - 33, 16)
                                 withAttributes:@{NSFontAttributeName: UIFont(11.5, NSFontWeightMedium), NSForegroundColorAttributeName: vDim, NSParagraphStyleAttributeName: ps}];
        }
    }
    if (self.blocked > 0) {
        NSString *n = self.blocked > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)self.blocked];
        NSDictionary *a = @{NSFontAttributeName: UIFont(8.5, NSFontWeightBold), NSForegroundColorAttributeName: vBg};
        NSSize sz = [n sizeWithAttributes:a];
        NSRect badge = NSMakeRect(NSMaxX(self.shieldBtn.frame) - sz.width - 7, NSMinY(self.shieldBtn.frame) + 15, sz.width + 6, 11);
        RoundRect(badge, 4, vDim);
        [n drawAtPoint:NSMakePoint(NSMinX(badge) + 3, NSMinY(badge) - 0.5) withAttributes:a];
    }
}
- (void)mouseUp:(NSEvent *)e { if (e.clickCount == 2) [self.window performZoom:nil]; }
@end

#pragma mark - Extensions panel (the puzzle button)

static const CGFloat kXRow = 40, kXHead = 44, kXFoot = 84, kXW = 320;
@implementation VExtPanel
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithBar:(VToolbar *)bar {
    NSArray *ids = [bar.extBtns valueForKey:@"identifier"];
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kXW, kXHead + ids.count * kXRow + kXFoot)])) return nil;
    self.bar = bar; self.ids = ids; self.hover = -1;
    for (NSUInteger i = 0; i < ids.count; i++) {
        NSString *ident = ids[i];
        CGFloat y = kXHead + i * kXRow;
        BOOL pinned = ExtensionPinned(ident);
        VButton *pin = [VButton symbol:pinned ? @"pin.fill" : @"pin" size:12 tip:pinned ? @"Unpin from toolbar" : @"Pin to toolbar" target:self action:@selector(pin:)];
        pin.identifier = ident; pin.active = pinned; pin.frame = NSMakeRect(kXW - 12 - 28, y + 6, 28, 28);
        [self addSubview:pin];
        if ([FExtHost.shared hasOptionsForID:ident]) {
            VButton *opt = [VButton symbol:@"gearshape" size:12 tip:@"Options" target:self action:@selector(options:)];
            opt.identifier = ident; opt.frame = NSMakeRect(kXW - 12 - 28 - 28, y + 6, 28, 28);
            [self addSubview:opt];
        }
    }
    return self;
}
- (NSRect)rowRect:(NSUInteger)i { return NSMakeRect(8, kXHead + i * kXRow, kXW - 16, kXRow); }
- (NSRect)footRect:(NSUInteger)i { CGFloat y = kXHead + self.ids.count * kXRow + 12; return NSMakeRect(8, y + i * 34, kXW - 16, 32); }
- (void)drawRect:(NSRect)dirty {
    NSDictionary *h = @{NSFontAttributeName: UIFont(13, NSFontWeightSemibold), NSForegroundColorAttributeName: vText};
    [@"Extensions" drawAtPoint:NSMakePoint(18, 16) withAttributes:h];
    NSString *n = [NSString stringWithFormat:@"%lu installed", (unsigned long)self.ids.count];
    NSDictionary *na = @{NSFontAttributeName: UIFont(11.5, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint};
    [n drawAtPoint:NSMakePoint(kXW - 18 - [n sizeWithAttributes:na].width, 18) withAttributes:na];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSUInteger i = 0; i < self.ids.count; i++) {
        NSRect r = [self rowRect:i];
        if ((NSInteger)i == self.hover) RoundRect(r, 8, vHover);
        NSImage *ic = [FExtHost.shared iconForID:self.ids[i]];
        if (ic) DrawImage(ic, NSMakeRect(NSMinX(r) + 10, NSMidY(r) - 9, 18, 18));
        NSString *name = [FExtHost.shared nameForID:self.ids[i]] ?: @"Extension";
        NSRange cut = [name rangeOfString:@" - "]; if (cut.location == NSNotFound) cut = [name rangeOfString:@": "];
        NSString *title = cut.location != NSNotFound ? [name substringToIndex:cut.location] : name;   // "Proton Pass: Free Password Manager" → "Proton Pass"
        BOOL hasOpt = [FExtHost.shared hasOptionsForID:self.ids[i]];
        [title drawInRect:NSMakeRect(NSMinX(r) + 38, NSMidY(r) - 9, NSWidth(r) - 38 - (hasOpt ? 64 : 36), 18)
           withAttributes:@{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: vText, NSParagraphStyleAttributeName: ps}];
    }
    [vSep setFill]; NSRectFill(NSMakeRect(16, kXHead + self.ids.count * kXRow + 6, kXW - 32, 1));
    NSArray *foot = @[@[@"puzzlepiece.extension", @"Manage extensions"], @[@"bag", @"Get more from the Chrome Web Store"]];
    for (NSUInteger i = 0; i < foot.count; i++) {
        NSRect r = [self footRect:i];
        if (self.hover == 100 + (NSInteger)i) RoundRect(r, 8, vHover);
        NSImage *im = Tinted(Symbol(foot[i][0], 12, NSFontWeightMedium), vDim);
        DrawImage(im, CenterIn(im.size, NSMakeRect(NSMinX(r) + 10, NSMinY(r), 18, NSHeight(r))));
        [foot[i][1] drawAtPoint:NSMakePoint(NSMinX(r) + 38, NSMinY(r) + 8) withAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightRegular), NSForegroundColorAttributeName: vDim}];
    }
}
- (NSInteger)itemAt:(NSPoint)p {
    for (NSUInteger i = 0; i < self.ids.count; i++) if (NSPointInRect(p, [self rowRect:i])) return (NSInteger)i;
    for (NSUInteger i = 0; i < 2; i++) if (NSPointInRect(p, [self footRect:i])) return 100 + (NSInteger)i;
    return -1;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas.copy) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e { NSInteger h = [self itemAt:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != self.hover) { self.hover = h; self.needsDisplay = YES; } }
- (void)mouseExited:(NSEvent *)e { self.hover = -1; self.needsDisplay = YES; }
- (void)mouseUp:(NSEvent *)e {
    NSInteger i = [self itemAt:[self convertPoint:e.locationInWindow fromView:nil]];
    VToolbar *bar = self.bar;
    [self.popover close];
    if (i >= 100) {
        if (i == 100) [gApp performSelector:@selector(showSettingsSection:) withObject:@7];
        else [WinFor(bar) newTab:[NSURL URLWithString:@"https://chromewebstore.google.com/"] select:YES];
        return;
    }
    if (i < 0) return;
    NSString *ident = self.ids[(NSUInteger)i];
    NSButton *pinned = (NSButton *)[bar extensionButtonFor:ident];
    for (id x in FExtHost.shared.extensions) if ([[x valueForKey:@"ident"] isEqualToString:ident])
        [FExtHost.shared openPopup:x from:(pinned && !pinned.hidden) ? pinned : bar.extMenuBtn];
}
- (void)pin:(VButton *)b {
    NSMutableArray *p = [[Defaults() arrayForKey:kExtPinned] ?: self.ids mutableCopy];
    BOOL now = ![p containsObject:b.identifier];
    if (now) [p addObject:b.identifier]; else [p removeObject:b.identifier];
    [Defaults() setObject:p forKey:kExtPinned];
    b.symbolName = now ? @"pin.fill" : @"pin"; b.active = now; b.toolTip = now ? @"Unpin from toolbar" : @"Pin to toolbar";
    for (VWindow *w in gWindows) { [w.toolbar layoutBar]; [w refreshChrome]; }
}
- (void)options:(VButton *)b { [self.popover close]; [FExtHost.shared openOptionsForID:b.identifier]; }
@end

#pragma mark - Suggestions under the address bar

@interface VSuggest : NSPanel
@property (strong) NSArray<NSDictionary *> *items;   // {kind: search|url, title, url}
@property NSInteger sel;
- (void)showBelow:(NSRect)screenRect items:(NSArray *)items;
- (void)dismiss;
- (NSDictionary *)selected;
- (void)move:(NSInteger)d;
@end

@interface VSuggestView : NSView
@property (weak) VSuggest *owner;
@end

@implementation VSuggest
- (instancetype)init {
    if (!(self = [super initWithContentRect:NSMakeRect(0, 0, 400, 200) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:YES])) return nil;
    self.opaque = NO; self.backgroundColor = NSColor.clearColor; self.hasShadow = YES;
    self.level = NSPopUpMenuWindowLevel; self.hidesOnDeactivate = YES;
    VSuggestView *v = [[VSuggestView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    v.owner = self; v.wantsLayer = YES;
    v.layer.backgroundColor = vCard.CGColor;
    self.contentView = v;
    return self;
}
- (BOOL)canBecomeKeyWindow { return NO; }

// Results are grouped: the top hit first, then open tabs, commands, history and bookmarks, searches.
static NSString *SuggestGroup(NSDictionary *it, NSUInteger i) {
    if (i == 0) return @"";
    NSString *k = it[@"kind"];
    return [k isEqualToString:@"tab"] ? @"Open tabs" : [k isEqualToString:@"command"] ? @"Commands" : [k isEqualToString:@"search"] ? @"Search" : @"History and bookmarks";
}
static const CGFloat kSugRow = 36, kSugHead = 24, kSugPad = 6;
- (void)layoutRows {
    NSMutableArray *ys = [NSMutableArray array], *heads = [NSMutableArray array];
    CGFloat y = kSugPad; NSString *last = nil;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        NSString *g = SuggestGroup(self.items[i], i);
        if (g.length && ![g isEqualToString:last]) { [heads addObject:@[@(y), g]]; y += kSugHead; }
        last = g;
        [ys addObject:@(y)]; y += kSugRow;
    }
    objc_setAssociatedObject(self, "ys", ys, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, "heads", heads, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, "h", @(y + kSugPad), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSArray *)rowYs { return objc_getAssociatedObject(self, "ys"); }
- (NSArray *)heads { return objc_getAssociatedObject(self, "heads"); }
- (void)showBelow:(NSRect)r items:(NSArray *)items {
    self.items = items; self.sel = 0;
    if (!items.count) { [self dismiss]; return; }
    [self layoutRows];
    CGFloat h = [objc_getAssociatedObject(self, "h") doubleValue];
    NSWindow *pw = gWin.window;
    CGFloat maxW = pw ? NSWidth(pw.frame) - 80 : 720;
    CGFloat w = MIN(MAX(NSWidth(r) + 40, 620), MIN(760, maxW));
    NSRect f = NSMakeRect(round(NSMidX(r) - w / 2), NSMinY(r) - h - 8, w, h);
    if (pw) f.origin.x = MAX(NSMinX(pw.frame) + 12, MIN(NSMaxX(pw.frame) - w - 12, NSMinX(f)));
    [self setFrame:f display:YES];
    FacetView(self.contentView, 12, vLine);
    self.contentView.layer.backgroundColor = vCard.CGColor;
    self.contentView.needsDisplay = YES;
    if (!self.isVisible) { [pw addChildWindow:self ordered:NSWindowAbove]; [self orderFront:nil]; }
}
- (void)dismiss {
    if (!self.isVisible) return;
    [self.parentWindow removeChildWindow:self]; [self orderOut:nil];
}
- (NSDictionary *)selected { return self.isVisible && self.sel >= 0 && self.sel < (NSInteger)self.items.count ? self.items[(NSUInteger)self.sel] : nil; }
- (void)move:(NSInteger)d {
    if (!self.items.count) return;
    self.sel = (self.sel + d + (NSInteger)self.items.count) % (NSInteger)self.items.count;
    self.contentView.needsDisplay = YES;
}
@end

@implementation VSuggestView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    VSuggest *o = self.owner;
    NSArray *ys = [o rowYs];
    for (NSArray *h in [o heads]) {
        [h[1] drawAtPoint:NSMakePoint(18, [h[0] doubleValue] + 7)
           withAttributes:@{NSFontAttributeName: UIFont(11, NSFontWeightSemibold), NSForegroundColorAttributeName: vFaint}];
    }
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSInteger i = 0; i < (NSInteger)o.items.count && i < (NSInteger)ys.count; i++) {
        NSDictionary *it = o.items[(NSUInteger)i];
        NSString *kind = it[@"kind"];
        NSRect r = NSMakeRect(kSugPad, [ys[(NSUInteger)i] doubleValue], NSWidth(self.bounds) - kSugPad * 2, kSugRow);
        BOOL on = i == o.sel;
        if (on) {
            RoundRect(r, 7, vActive);
        }
        NSImage *fav = it[@"url"] ? [VFavicons.shared iconForURL:it[@"url"]] : nil;
        NSString *sym = [kind isEqualToString:@"search"] ? @"magnifyingglass" : [kind isEqualToString:@"command"] ? (it[@"symbol"] ?: @"command") : [kind isEqualToString:@"tab"] ? @"square.on.square" : @"globe";
        NSImage *icon = (fav && ![kind isEqualToString:@"search"] && ![kind isEqualToString:@"command"]) ? fav : Tinted(Symbol(sym, 12.5, NSFontWeightMedium), on ? vText : vDim);
        NSSize is = icon == fav ? NSMakeSize(16, 16) : icon.size;
        DrawImage(icon, CenterIn(is, NSMakeRect(NSMinX(r) + 12, NSMinY(r), 20, kSugRow)));
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:it[@"title"] ?: @""
            attributes:@{NSFontAttributeName: UIFont(13.5, i == 0 ? NSFontWeightSemibold : NSFontWeightRegular), NSForegroundColorAttributeName: vText, NSParagraphStyleAttributeName: ps}];
        NSString *detail = it[@"detail"];
        if (detail.length && ![kind isEqualToString:@"command"]) [t appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:detail]
            attributes:@{NSFontAttributeName: UIFont(12, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint, NSParagraphStyleAttributeName: ps}]];
        // what Return will do, on the right
        NSString *hint = [kind isEqualToString:@"command"] ? (it[@"keys"] ?: @"") : on ? ([kind isEqualToString:@"tab"] ? @"Switch  ↩" : [kind isEqualToString:@"search"] ? @"Search  ↩" : @"Open  ↩") : @"";
        CGFloat hw = 0;
        if (hint.length) {
            NSDictionary *ha = @{NSFontAttributeName: UIFont(11.5, NSFontWeightMedium), NSForegroundColorAttributeName: vFaint};
            hw = [hint sizeWithAttributes:ha].width;
            [hint drawAtPoint:NSMakePoint(NSMaxX(r) - hw - 14, NSMinY(r) + 11) withAttributes:ha];
        }
        [t drawInRect:NSMakeRect(NSMinX(r) + 42, NSMinY(r) + 9.5, NSWidth(r) - 60 - hw, 18)];
    }
}
- (NSInteger)rowAt:(NSPoint)p {
    NSArray *ys = [self.owner rowYs];
    for (NSUInteger i = 0; i < ys.count; i++) { CGFloat y = [ys[i] doubleValue]; if (p.y >= y && p.y < y + kSugRow) return (NSInteger)i; }
    return -1;
}
- (void)mouseDown:(NSEvent *)e {
    NSInteger i = [self rowAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i >= 0 && i < (NSInteger)self.owner.items.count) {
        self.owner.sel = i;
        NSDictionary *it = self.owner.items[(NSUInteger)i];
        [self.owner dismiss];
        [WinFor(self.owner.parentWindow ?: gWin.window) useSuggestion:it newTab:(e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) != 0];
    }
}
@end

#pragma mark - Bookmarks bar

@interface VBookmarksBar : NSView <NSDraggingSource>
@property (strong) NSMutableArray<NSValue *> *rects;
@property NSInteger hover, firstHidden;
@property NSInteger pressIndex;          // the bookmark the mouse went down on (a click or the start of a drag)
@property NSPoint pressAt;
@property NSInteger dropIndex, dropFolder;   // while something is dragged over the bar: where it would land
- (void)reload;
@end

// Every window's bar and star show the change.
static void BookmarksChanged(void) { [VBookmarks.shared save]; for (VWindow *w in gWindows) { [w.bookmarksBar reload]; [w refreshChrome]; } }

// Bookmark moves: the node being dragged (from the bar or any folder menu), and tree edits that work at any depth.
static NSMutableDictionary *gDragBookmark;
static char kBMNodeKey;
static NSMutableArray *BMChildren(NSMutableDictionary *folder) {   // a folder's list, made editable if it came in read-only
    if (![folder isKindOfClass:NSMutableDictionary.class]) return nil;
    if (![folder[@"children"] isKindOfClass:NSMutableArray.class]) folder[@"children"] = [folder[@"children"] ?: @[] mutableCopy];
    return folder[@"children"];
}
static BOOL BMRemove(NSMutableArray *list, id n) {
    NSUInteger i = [list indexOfObjectIdenticalTo:n];
    if (i != NSNotFound) { [list removeObjectAtIndex:i]; return YES; }
    for (NSMutableDictionary *x in list) if ([x isKindOfClass:NSDictionary.class] && x[@"children"] && BMRemove(BMChildren(x), n)) return YES;
    return NO;
}
static BOOL BMContains(NSDictionary *folder, id n) {   // n is folder or somewhere inside it
    if (folder == n) return YES;
    for (NSDictionary *x in [folder[@"children"] isKindOfClass:NSArray.class] ? folder[@"children"] : @[]) if (BMContains(x, n)) return YES;
    return NO;
}
// Put `node` (already a bookmark: moved; new: added) into `list` at `index` (NSNotFound = the end).
static BOOL BMPlace(NSMutableDictionary *node, NSMutableArray *list, NSUInteger index) {
    if (!node || !list) return NO;
    NSUInteger old = [list indexOfObjectIdenticalTo:node];
    BMRemove(VBookmarks.shared.bar, node);
    if (index == NSNotFound || index > list.count) index = list.count;
    else if (old != NSNotFound && old < index) index--;
    [list insertObject:node atIndex:MIN(index, list.count)];
    return YES;
}
static NSArray *DroppedLink(NSPasteboard *pb);
static NSMutableDictionary *DraggedBookmark(id<NSDraggingInfo> info) {
    return [info.draggingPasteboard stringForType:kBookmarkDragType] && gDragBookmark ? gDragBookmark : nil;
}

static NSMenu *BookmarkMenu(NSMutableArray *list, NSUInteger from);

// What makes a folder's menu (and the bar's overflow menu) editable: drag items out, reorder, drop pages and
// bookmarks in, right-click an item.
@interface VBookmarkMenuTarget : NSObject <VMenuDropTarget>
@property (strong) NSMutableArray *list;
@property NSUInteger from;
@end
@implementation VBookmarkMenuTarget
- (NSMutableDictionary *)nodeFor:(NSMenuItem *)i { return i ? objc_getAssociatedObject(i, &kBMNodeKey) : nil; }
- (BOOL)itemIsDraggable:(NSMenuItem *)i { return [self nodeFor:i] != nil; }
- (BOOL)menu:(NSMenu *)m beginDragFor:(NSMenuItem *)i event:(NSEvent *)e view:(NSView<NSDraggingSource> *)v {
    NSMutableDictionary *n = [self nodeFor:i]; if (!n) return NO;
    gDragBookmark = n;
    NSImage *icon = n[@"children"] ? Tinted(Symbol(@"folder", 13, NSFontWeightRegular), vDim) : [VFavicons.shared iconForURL:n[@"url"]];
    BeginURLDrag(v, e, n[@"url"], [n[@"name"] length] ? n[@"name"] : n[@"url"], icon, @"node");
    return YES;
}
- (NSDragOperation)menu:(NSMenu *)m validateDrop:(id<NSDraggingInfo>)info before:(NSMenuItem *)item into:(NSMenuItem *)folder {
    NSMutableDictionary *moving = DraggedBookmark(info), *target = [self nodeFor:folder];
    if (!moving && !DroppedLink(info.draggingPasteboard)) return NSDragOperationNone;
    if (moving && target && BMContains(moving, target)) return NSDragOperationNone;   // a folder into itself
    if (moving && [self nodeFor:item] == moving) return NSDragOperationNone;
    return moving ? NSDragOperationMove : NSDragOperationCopy;
}
- (BOOL)menu:(NSMenu *)m acceptDrop:(id<NSDraggingInfo>)info before:(NSMenuItem *)item into:(NSMenuItem *)folder {
    NSMutableDictionary *node = DraggedBookmark(info);
    if (!node) { NSArray *link = DroppedLink(info.draggingPasteboard); if (!link) return NO; node = [@{@"name": link[1], @"url": link[0]} mutableCopy]; }
    NSMutableDictionary *target = [self nodeFor:folder];
    if (target) { if (BMContains(node, target)) return NO; BMPlace(node, BMChildren(target), NSNotFound); }
    else {
        NSMutableDictionary *b = [self nodeFor:item];
        NSUInteger at = b ? [self.list indexOfObjectIdenticalTo:b] : NSNotFound;   // an item past the bookmarks ("Open All"): the end
        BMPlace(node, self.list, at);
    }
    gDragBookmark = nil;
    BookmarksChanged();
    return YES;
}
- (NSMenu *)menu:(NSMenu *)m contextMenuFor:(NSMenuItem *)i {
    NSMutableDictionary *n = [self nodeFor:i]; if (!n) return nil;
    NSMenu *c = [[NSMenu alloc] initWithTitle:@""];
    VWindow *w = gWin;
    NSMenuItem *(^add)(NSString *, SEL, id) = ^NSMenuItem *(NSString *t, SEL a, id obj) { NSMenuItem *it = [c addItemWithTitle:t action:a keyEquivalent:@""]; it.target = w; it.representedObject = obj; return it; };
    if (n[@"url"]) {
        add(@"Open in New Tab", @selector(openBookmarkInNewTab:), n[@"url"]);
        add(@"Open in Background Tab", @selector(openBookmarkInBackground:), n[@"url"]);
        add(@"Copy Link", @selector(copyText:), n[@"url"]);
        [c addItem:NSMenuItem.separatorItem];
        add(@"Edit…", @selector(editBookmark:), n);
    } else {
        NSMutableArray *urls = [NSMutableArray array]; for (NSDictionary *x in n[@"children"]) if (x[@"url"]) [urls addObject:x[@"url"]];
        add([NSString stringWithFormat:@"Open All in Tabs (%lu)", (unsigned long)urls.count], @selector(openAllBookmarks:), urls).enabled = urls.count > 0;
        [c addItem:NSMenuItem.separatorItem];
        add(@"Rename…", @selector(editBookmark:), n);
    }
    add(@"Delete", @selector(deleteBookmark:), n);
    return c;
}
@end

static NSMenu *BookmarkMenu(NSMutableArray *list, NSUInteger from) {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    VBookmarkMenuTarget *t = [VBookmarkMenuTarget new]; t.list = list; t.from = from;
    objc_setAssociatedObject(m, &kMenuDropKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray *urls = [NSMutableArray array];
    for (NSUInteger k = from; k < list.count; k++) {
        NSMutableDictionary *n = list[k];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:[n[@"name"] length] ? n[@"name"] : (HostOf([NSURL URLWithString:n[@"url"]]) ?: @"") action:nil keyEquivalent:@""];
        objc_setAssociatedObject(it, &kBMNodeKey, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (n[@"children"]) {
            it.image = Symbol(@"folder", 12, NSFontWeightRegular);
            it.submenu = BookmarkMenu(BMChildren(n) ?: [NSMutableArray array], 0);
        } else {
            NSImage *ic = [VFavicons.shared iconForURL:n[@"url"]];
            if (ic) { NSImage *s = [ic copy]; s.size = NSMakeSize(16, 16); it.image = s; }
            it.target = gWin; it.action = @selector(openBookmarkItem:); it.representedObject = n[@"url"];
            if (n[@"url"]) [urls addObject:n[@"url"]];
        }
        [m addItem:it];
    }
    if (from >= list.count) [m addItemWithTitle:@"Empty · drop pages here" action:nil keyEquivalent:@""];
    if (urls.count > 1) {
        [m addItem:NSMenuItem.separatorItem];
        NSMenuItem *all = [m addItemWithTitle:[NSString stringWithFormat:@"Open All (%lu)", (unsigned long)urls.count] action:@selector(openAllBookmarks:) keyEquivalent:@""];
        all.target = gWin; all.representedObject = urls;
    }
    return m;
}

@implementation VBookmarksBar
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) return nil;
    self.pressIndex = -1; self.dropIndex = -1; self.dropFolder = -1;
    // pages (the site button, a tab from the sidebar, links from pages and other apps) and bookmarks being moved
    [self registerForDraggedTypes:@[kBookmarkDragType, NSPasteboardTypeURL, @"WebURLsWithTitlesPboardType", NSPasteboardTypeString]];
    return self;
}
- (void)reload { self.needsDisplay = YES; }

- (NSString *)labelFor:(NSDictionary *)n { return n[@"name"] ?: @""; }

- (void)drawRect:(NSRect)dirty {
    [vBg setFill]; NSRectFill(NSIntersectionRect(dirty, self.bounds));
    self.rects = [NSMutableArray array];
    NSArray *bar = VBookmarks.shared.bar;
    CGFloat x = 6, limit = NSWidth(self.bounds) - 34;
    NSDictionary *ta = @{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: [vText colorWithAlphaComponent:0.9]};
    self.firstHidden = -1;
    for (NSUInteger i = 0; i < bar.count; i++) {
        NSDictionary *n = bar[i];
        NSString *label = [self labelFor:n];
        if (label.length > 22) label = [[label substringToIndex:21] stringByAppendingString:@"…"];
        CGFloat tw = label.length ? ceil([label sizeWithAttributes:ta].width) : 0;
        CGFloat w = 7 + 16 + (tw ? 7 + tw + 3 : 0) + 7;
        if (x + w > limit) { self.firstHidden = (NSInteger)i; break; }
        NSRect r = NSMakeRect(x, 2, w, 26);
        [self.rects addObject:[NSValue valueWithRect:r]];
        if ((NSInteger)i == self.hover) RoundRect(r, 7, vHover);
        NSImage *fav = n[@"children"] ? nil : [VFavicons.shared iconForURL:n[@"url"]];
        NSImage *icon = fav ?: Tinted(Symbol(n[@"children"] ? @"folder" : @"globe", 13.5, NSFontWeightRegular), [vText colorWithAlphaComponent:0.8]);
        NSSize is = fav ? NSMakeSize(16, 16) : icon.size;
        DrawImage(icon, CenterIn(is, NSMakeRect(x + 7, 2, 16, 26)));
        if (tw) [label drawAtPoint:NSMakePoint(x + 7 + 16 + 7, 2 + round((26 - 17) / 2)) withAttributes:ta];
        x += w;
    }
    // where a dragged page or bookmark would land: into a folder, or a thin line between two bookmarks
    if (self.dropFolder >= 0 && self.dropFolder < (NSInteger)self.rects.count) ShardStroke(self.rects[(NSUInteger)self.dropFolder].rectValue, 7, vAccent, 1.5);
    else if (self.dropIndex >= 0) {
        CGFloat lx = self.rects.count == 0 ? 6 : self.dropIndex < (NSInteger)self.rects.count ? NSMinX(self.rects[(NSUInteger)self.dropIndex].rectValue) : NSMaxX(self.rects.lastObject.rectValue);
        RoundRect(NSMakeRect(lx - 1, 5, 2, 20), 1, vAccent);
    }
    if (self.firstHidden >= 0) {
        NSRect more = NSMakeRect(NSWidth(self.bounds) - 30, 3, 24, 24);
        if (self.hover == 999) RoundRect(more, 6, vHover);
        NSImage *im = Tinted(Symbol(@"chevron.right.2", 11, NSFontWeightRegular), vDim);
        DrawImage(im, CenterIn(im.size, more));
    }
}

- (NSInteger)indexAt:(NSPoint)p {
    for (NSUInteger i = 0; i < self.rects.count; i++) if (NSPointInRect(p, self.rects[i].rectValue)) return (NSInteger)i;
    if (self.firstHidden >= 0 && p.x > NSWidth(self.bounds) - 32) return 999;
    return -1;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas.copy) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e {
    NSInteger h = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (h != self.hover) { self.hover = h; self.needsDisplay = YES; }
}
- (void)mouseExited:(NSEvent *)e { self.hover = -1; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = [self indexAt:p];
    self.pressIndex = -1;
    if (i == 999) {
        PopMenuRight(BookmarkMenu(VBookmarks.shared.bar, (NSUInteger)self.firstHidden), NSMakePoint(NSWidth(self.bounds) - 6, 28), self);
        return;
    }
    if (i < 0) { if (e.clickCount == 2) [self.window performZoom:nil]; else [self.window performWindowDragWithEvent:e]; return; }
    self.pressIndex = i; self.pressAt = p;   // opens on release; moving first starts a drag
}
- (void)mouseDragged:(NSEvent *)e {
    if (self.pressIndex < 0 || self.pressIndex >= (NSInteger)VBookmarks.shared.bar.count) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (hypot(p.x - self.pressAt.x, p.y - self.pressAt.y) < 4) return;
    NSDictionary *n = VBookmarks.shared.bar[(NSUInteger)self.pressIndex];
    NSInteger i = self.pressIndex; self.pressIndex = -1; self.hover = -1; self.needsDisplay = YES;
    NSImage *icon = n[@"children"] ? Tinted(Symbol(@"folder", 13, NSFontWeightRegular), vDim) : [VFavicons.shared iconForURL:n[@"url"]];
    gDragBookmark = (NSMutableDictionary *)n; (void)i;
    BeginURLDrag(self, e, n[@"url"], [self labelFor:n].length ? [self labelFor:n] : n[@"url"], icon, @"node");
}
- (void)mouseUp:(NSEvent *)e {
    NSInteger i = self.pressIndex; self.pressIndex = -1;
    NSArray *bar = VBookmarks.shared.bar;
    if (i < 0 || i >= (NSInteger)bar.count || i >= (NSInteger)self.rects.count) return;
    if ([self indexAt:[self convertPoint:e.locationInWindow fromView:nil]] != i) return;   // let go somewhere else: nothing
    NSDictionary *n = bar[(NSUInteger)i];
    NSRect r = self.rects[(NSUInteger)i].rectValue;
    if (n[@"children"]) { PopMenu(BookmarkMenu(BMChildren((NSMutableDictionary *)n), 0), NSMakePoint(NSMinX(r), NSMaxY(r) + 3), self); return; }
    [WinFor(self) openURL:[NSURL URLWithString:n[@"url"]] newTab:(e.modifierFlags & NSEventModifierFlagCommand) != 0];
}

#pragma mark Drag and drop

- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c {
    return c == NSDraggingContextWithinApplication ? NSDragOperationMove | NSDragOperationCopy : NSDragOperationCopy;
}
// Where a drop at this point lands: the middle of a folder means into it; otherwise before or after the nearest bookmark.
- (void)targetFor:(NSPoint)p moving:(NSInteger)from {
    NSArray *bar = VBookmarks.shared.bar;
    self.dropFolder = -1; self.dropIndex = (NSInteger)self.rects.count;
    for (NSUInteger k = 0; k < self.rects.count; k++) {
        NSRect r = self.rects[k].rectValue;
        if (p.x > NSMaxX(r)) continue;
        if (bar[k][@"children"] && (NSInteger)k != from && p.x > NSMinX(r) + NSWidth(r) * 0.25 && p.x < NSMaxX(r) - NSWidth(r) * 0.25) { self.dropFolder = (NSInteger)k; self.dropIndex = -1; return; }
        self.dropIndex = p.x < NSMidX(r) ? (NSInteger)k : (NSInteger)k + 1;
        return;
    }
}
- (NSInteger)movingIndex:(id<NSDraggingInfo>)info {   // where the bookmark being moved sits on the bar (-1: in a folder, or not a move)
    NSMutableDictionary *n = DraggedBookmark(info); if (!n) return -1;
    NSUInteger i = [VBookmarks.shared.bar indexOfObjectIdenticalTo:n];
    return i == NSNotFound ? -1 : (NSInteger)i;
}
// The address (and a title, when the source gave one) from whatever was dragged in.
static NSArray *DroppedLink(NSPasteboard *pb) {
    NSString *url = [pb stringForType:NSPasteboardTypeURL], *title = [pb stringForType:@"public.url-name"];
    id webkit = [pb propertyListForType:@"WebURLsWithTitlesPboardType"];   // WebKit's own link drags: [[urls], [titles]]
    if ([webkit isKindOfClass:NSArray.class] && [webkit count] == 2) {
        if (!url.length) url = [[webkit[0] firstObject] description];
        if (!title.length) title = [[webkit[1] firstObject] description];
    }
    if (!url.length) { NSString *t = Trim([pb stringForType:NSPasteboardTypeString] ?: @""); if ([t hasPrefix:@"http://"] || [t hasPrefix:@"https://"]) url = t; }
    NSURL *u = url.length ? [NSURL URLWithString:url] : nil;
    if (!u || !([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"] || [u.scheme isEqualToString:@"file"])) return nil;
    if (!title.length) for (VTab *t in AllTabs(NO)) if ([t.url isEqualToString:u.absoluteString] && t.title.length) { title = t.title; break; }
    if (!title.length) title = HostOf(u) ?: u.absoluteString;
    return @[u.absoluteString, title];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    NSInteger from = [self movingIndex:info];
    NSMutableDictionary *moving = DraggedBookmark(info);
    if (!moving && !DroppedLink(info.draggingPasteboard)) { self.dropIndex = self.dropFolder = -1; self.needsDisplay = YES; return NSDragOperationNone; }
    [self targetFor:[self convertPoint:info.draggingLocation fromView:nil] moving:from];
    if (from >= 0 && self.dropFolder < 0 && (self.dropIndex == from || self.dropIndex == from + 1)) self.dropIndex = -1;   // no move
    if (moving && self.dropFolder >= 0 && BMContains(moving, VBookmarks.shared.bar[(NSUInteger)self.dropFolder])) self.dropFolder = -1;
    self.needsDisplay = YES;
    return moving ? NSDragOperationMove : NSDragOperationCopy;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [self draggingUpdated:info]; }
- (void)draggingExited:(id<NSDraggingInfo>)info { self.dropIndex = self.dropFolder = -1; self.needsDisplay = YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSMutableArray *bar = VBookmarks.shared.bar;
    NSInteger to = self.dropIndex, folder = self.dropFolder;
    self.dropIndex = self.dropFolder = -1; self.needsDisplay = YES;
    if (to < 0 && folder < 0) return NO;
    NSMutableDictionary *node = DraggedBookmark(info);
    if (!node) { NSArray *link = DroppedLink(info.draggingPasteboard); if (!link) return NO; node = [@{@"name": link[1], @"url": link[0]} mutableCopy]; }   // a page or link: a new bookmark
    NSMutableDictionary *target = folder >= 0 && folder < (NSInteger)bar.count ? bar[(NSUInteger)folder] : nil;
    if (target) { if (BMContains(node, target)) return NO; BMPlace(node, BMChildren(target), NSNotFound); }
    else {   // the insertion point counts bar positions; place before the bookmark now there (or at the end)
        NSMutableDictionary *before = to < (NSInteger)bar.count ? bar[(NSUInteger)to] : nil;
        if (before == node) return NO;
        BMPlace(node, bar, before ? [bar indexOfObjectIdenticalTo:before] : NSNotFound);
    }
    gDragBookmark = nil;
    BookmarksChanged();
    if (target) [WinFor(self) showToast:[NSString stringWithFormat:@"Moved into %@", target[@"name"] ?: @"folder"]];
    return YES;
}
- (void)otherMouseDown:(NSEvent *)e {
    NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i >= 0 && i != 999 && !VBookmarks.shared.bar[(NSUInteger)i][@"children"]) [WinFor(self) openURL:[NSURL URLWithString:VBookmarks.shared.bar[(NSUInteger)i][@"url"]] newTab:YES];
}
- (void)rightMouseDown:(NSEvent *)e {
    NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *(^add)(NSString *, SEL, id) = ^NSMenuItem *(NSString *t, SEL a, id obj) { NSMenuItem *it = [m addItemWithTitle:t action:a keyEquivalent:@""]; it.target = WinFor(self); it.representedObject = obj; return it; };
    NSMutableDictionary *n = (i >= 0 && i != 999) ? VBookmarks.shared.bar[(NSUInteger)i] : nil;
    if (n[@"url"]) {
        add(@"Open in New Tab", @selector(openBookmarkInNewTab:), n[@"url"]);
        add(@"Open in Background Tab", @selector(openBookmarkInBackground:), n[@"url"]);
        add(@"Open in Default Browser", @selector(openInDefaultBrowser:), n[@"url"]);
        [m addItem:NSMenuItem.separatorItem];
        add(@"Copy Link", @selector(copyText:), n[@"url"]);
        [m addItem:NSMenuItem.separatorItem];
    } else if (n[@"children"]) {
        NSMutableArray *urls = [NSMutableArray array];
        for (NSDictionary *c in n[@"children"]) if (c[@"url"]) [urls addObject:c[@"url"]];
        add([NSString stringWithFormat:@"Open All in Tabs (%lu)", (unsigned long)urls.count], @selector(openAllBookmarks:), urls).enabled = urls.count > 0;
        [m addItem:NSMenuItem.separatorItem];
    }
    if (n) {
        add(n[@"children"] ? @"Rename Folder…" : @"Edit…", @selector(editBookmark:), n);
        add(@"Delete", @selector(deleteBookmark:), n);
        [m addItem:NSMenuItem.separatorItem];
    }
    if (!WinFor(self).current.isHome && WinFor(self).current.url) add([VBookmarks.shared find:WinFor(self).current.url] ? @"Remove Bookmark for This Page" : @"Bookmark This Page", @selector(toggleBookmark:), nil);
    add(@"New Folder…", @selector(newBookmarkFolder:), n);
    add(@"Bookmark Manager", @selector(showBookmarks:), nil);
    add(@"Hide Bookmarks Bar", @selector(toggleBookmarksBar:), nil);
    PopMenuForEvent(m, e, self);
}
@end

#pragma mark - Sidebar: pinned tabs and the tab list

@interface VSidebar : NSView <NSDraggingSource>
@property NSInteger hoverRow;      // index into WinFor(self).tabs, -2 = "New tab" row
@property BOOL hoverClose;
@property (strong) VTab *dragTab;
@property NSPoint downAt;
@property NSInteger dropIndex;
@property BOOL dragging;
- (void)reload;
@end

@implementation VSidebar
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

static const CGFloat kPinH = 36, kPad = 8;
// sidebar row height follows the density setting
static CGFloat RowH(void) { NSInteger d = [Defaults() integerForKey:kDensity]; return d == 0 ? 27 : d == 2 ? 38 : 32; }
#define kRowH RowH()

- (NSArray<VTab *> *)pinned { return [WinFor(self).tabs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pinned == YES"]]; }
- (NSArray<VTab *> *)loose { return [WinFor(self).tabs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pinned == NO"]]; }
- (NSInteger)cols { return MAX(1, (NSInteger)((NSWidth(self.bounds) - kPad * 2 + 6) / 52)); }
- (CGFloat)pinBlockH {
    NSUInteger n = self.pinned.count; if (!n) return 0;
    NSInteger rows = ((NSInteger)n + self.cols - 1) / self.cols;
    return rows * (kPinH + 6) + 6;
}
- (NSRect)pinRect:(NSUInteger)i {
    NSInteger c = self.cols; CGFloat w = (NSWidth(self.bounds) - kPad * 2 - (c - 1) * 6) / c;
    return NSMakeRect(round(kPad + (i % (NSUInteger)c) * (w + 6)), 1 + (i / (NSUInteger)c) * (kPinH + 6), floor(w), kPinH);
}
- (BOOL)compact { return NSWidth(self.bounds) < 100; }   // narrow sidebar: a column of icons
// The first tab lines up with the bookmarks bar (the sidebar runs up to the toolbar), and "New tab" follows the list.
- (CGFloat)listTop { return self.pinned.count ? 1 + self.pinBlockH + (self.compact ? 6 : 4) : MAX(0, round(15 - kRowH / 2)); }   // 15: the bookmarks' midline
- (NSRect)rowRect:(NSUInteger)i { return NSMakeRect(kPad, self.listTop + i * (kRowH + 2), NSWidth(self.bounds) - kPad * 2, kRowH); }
- (NSRect)newRect { NSRect r = [self rowRect:self.loose.count]; r.origin.y += 2; return r; }

- (void)reload {
    CGFloat h = NSMaxY([self newRect]) + 12;
    NSScrollView *sv = self.enclosingScrollView;
    [self setFrameSize:NSMakeSize(NSWidth(sv.contentView.bounds), MAX(h, NSHeight(sv.contentView.bounds)))];
    self.needsDisplay = YES;
}

static void EmberSliver(NSRect r) { RoundRect(r, MIN(NSWidth(r), NSHeight(r)) / 2, [vText colorWithAlphaComponent:0.45]); }
- (void)drawRect:(NSRect)dirty {
    [vBg setFill]; NSRectFill(NSIntersectionRect(dirty, self.bounds));
    VWindow *win = WinFor(self);
    if (!win.isPrivate && Profiles().count > 1) {   // which profile this window is, without reading anything
        [[ProfileColor(win.profile) colorWithAlphaComponent:ThemeIsLight() ? 0.07 : 0.06] setFill];
        NSRectFillUsingOperation(NSIntersectionRect(dirty, self.bounds), NSCompositingOperationSourceOver);
    }
    NSArray *pins = self.pinned, *loose = self.loose;
    // pinned: struck tiles; the open one carries the spark along its foot
    for (NSUInteger i = 0; i < pins.count; i++) {
        VTab *t = pins[i]; NSRect r = [self pinRect:i];
        BOOL on = t == win.current, hov = self.hoverRow == (NSInteger)[win.tabs indexOfObject:t];
        RoundRect(r, 9, on ? vActive : hov ? vHover : vPill);
        NSImage *ic = t.favicon ?: Tinted(Symbol(@"globe", 13, NSFontWeightRegular), vDim);
        DrawImage(ic, CenterIn(t.favicon ? NSMakeSize(18, 18) : ic.size, r));
        if (on) ShardStroke(r, 9, vLine, 1);
        if (t.loading) RoundRect(NSMakeRect(NSMidX(r) - 9, NSMaxY(r) - 4, 18, 2), 1, [vText colorWithAlphaComponent:0.35]);
    }
    BOOL compact = self.compact;
    if (pins.count) { [vSep setFill]; NSRectFill(NSMakeRect(kPad + 6, self.listTop - 3, NSWidth(self.bounds) - kPad * 2 - 12, 1)); }
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSUInteger i = 0; i < loose.count; i++) {
        VTab *t = loose[i]; NSRect r = [self rowRect:i];
        NSInteger idx = (NSInteger)[win.tabs indexOfObject:t];
        BOOL on = t == win.current, hov = self.hoverRow == idx;
        BOOL beside = !on && [win.splitPair containsObject:t] && [win.splitPair containsObject:win.current];   // the other half of a split
        if (on) RoundRect(r, 8, vActive);
        else if (hov || beside) RoundRect(r, 8, vHover);
        if (compact) {   // icon only; the open tab offers its close button on hover
            if (on && hov) {
                if (self.hoverClose) RoundRect(NSInsetRect(r, 4, 4), 6, vCloseHover);
                NSImage *xi = Tinted(Symbol(@"xmark", 10, NSFontWeightSemibold), vText);
                DrawImage(xi, CenterIn(xi.size, r));
            } else if (t.loading) {
                NSImage *sp = Tinted(Symbol(@"circle.dotted", 12, NSFontWeightRegular), vDim);
                DrawImage(sp, CenterIn(sp.size, r));
            } else {
                NSImage *ic = t.favicon ?: Tinted(Symbol(t.isHome ? @"sparkle" : @"globe", 12, NSFontWeightRegular), vDim);
                NSSize sz = t.favicon ? NSMakeSize(16, 16) : ic.size;
                [ic drawInRect:CenterIn(sz, r) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:(t.web || t.isHome) ? 1 : 0.45 respectFlipped:YES hints:nil];
            }
            if ((t.audible || t.muted) && !(on && hov)) {
                NSImage *sp = Tinted(Symbol(t.muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill", 8, NSFontWeightBold), vDim);
                DrawImage(sp, NSMakeRect(NSMaxX(r) - sp.size.width - 3, NSMinY(r) + 3, sp.size.width, sp.size.height));
            }
            continue;
        }
        if (t.loading) {
            NSImage *sp = Tinted(Symbol(@"circle.dotted", 12, NSFontWeightRegular), vDim);
            DrawImage(sp, CenterIn(sp.size, NSMakeRect(NSMinX(r) + 9, NSMinY(r), 16, kRowH)));
        } else {
            NSImage *ic = t.favicon ?: Tinted(Symbol(t.isHome ? @"sparkle" : @"globe", 12, NSFontWeightRegular), vDim);
            NSSize sz = t.favicon ? NSMakeSize(16, 16) : ic.size;
            NSImage *draw = ic;
            if (t.web == nil && !t.isHome && t.favicon) {   // asleep: dim the icon
                draw = [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect rr) { [ic drawInRect:rr fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.45]; return YES; }];
            }
            DrawImage(draw, CenterIn(sz, NSMakeRect(NSMinX(r) + 9, NSMinY(r), 16, kRowH)));
        }
        CGFloat tw = NSWidth(r) - 38 - ((hov || on) ? 24 : 6) - ((t.audible || t.muted) ? 20 : 0);
        if (t.audible || t.muted) {
            NSImage *sp = Tinted(Symbol(t.muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill", 11, NSFontWeightRegular), t.muted ? vFaint : vDim);
            DrawImage(sp, CenterIn(sp.size, NSMakeRect(NSMaxX(r) - ((hov || on) ? 44 : 24), NSMinY(r), 18, kRowH)));
        }
        NSString *title = t.title.length ? t.title : (t.isHome ? @"New Tab" : (t.url ?: @""));
        NSColor *tc = on ? vText : (t.web || t.isHome ? [vText colorWithAlphaComponent:0.78] : vDim);
        [title drawInRect:NSMakeRect(NSMinX(r) + 34, NSMinY(r) + round((kRowH - 17) / 2), tw, 17)
           withAttributes:@{NSFontAttributeName: UIFont(13, on ? NSFontWeightMedium : NSFontWeightRegular), NSForegroundColorAttributeName: tc, NSParagraphStyleAttributeName: ps}];
        if (hov || on) {
            NSRect x = NSMakeRect(NSMaxX(r) - 24, NSMidY(r) - 10, 20, 20);
            if (hov && self.hoverClose) RoundRect(x, 5, vCloseHover);
            NSImage *xi = Tinted(Symbol(@"xmark", 9, NSFontWeightSemibold), vDim);
            DrawImage(xi, CenterIn(xi.size, x));
        }
    }
    if ([win.splitPair containsObject:win.current]) {   // a split reads as one joined pair
        NSUInteger a = [loose indexOfObject:win.splitPair[0]], b = [loose indexOfObject:win.splitPair[1]];
        if (a != NSNotFound && b != NSNotFound && (a + 1 == b || b + 1 == a)) ShardStroke(NSInsetRect(NSUnionRect([self rowRect:a], [self rowRect:b]), -2, -2), 10, vLine, 1);
    }
    if (self.dragging && self.dropIndex >= 0) {
        NSRect r = [self rowRect:(NSUInteger)self.dropIndex];
        EmberSliver(NSMakeRect(NSMinX(r) + 4, NSMinY(r) - 2, NSWidth(r) - 8, 2));
    }
    NSRect nr = [self newRect];
    BOOL nh = self.hoverRow == -2;
    RoundRect(nr, 9, nh ? vHover : vPill);
    if (compact) {
        NSImage *pl = Tinted(Symbol(@"plus", 12.5, NSFontWeightMedium), nh ? vText : vDim);
        DrawImage(pl, CenterIn(pl.size, nr));
        return;
    }
    NSImage *plus = Tinted(Symbol(@"plus", 12.5, NSFontWeightMedium), nh ? vText : vDim);
    DrawImage(plus, CenterIn(plus.size, NSMakeRect(NSMinX(nr) + 9, NSMinY(nr), 16, NSHeight(nr))));
    NSDictionary *na = @{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: nh ? vText : vDim};
    [@"New tab" drawAtPoint:NSMakePoint(NSMinX(nr) + 34, NSMinY(nr) + round((NSHeight(nr) - 17) / 2)) withAttributes:na];
    NSDictionary *ka = @{NSFontAttributeName: UIFont(11, NSFontWeightMedium), NSForegroundColorAttributeName: vFaint};
    NSSize ks = [@"⌘T" sizeWithAttributes:ka];
    if (nh) [@"⌘T" drawAtPoint:NSMakePoint(NSMaxX(nr) - ks.width - 10, NSMinY(nr) + round((NSHeight(nr) - 15) / 2)) withAttributes:ka];
}

// Which tab (index into WinFor(self).tabs) is under the point; -2 for "New tab"; -1 for nothing.
- (NSInteger)hit:(NSPoint)p close:(BOOL *)onClose {
    if (onClose) *onClose = NO;
    NSArray *pins = self.pinned, *loose = self.loose;
    for (NSUInteger i = 0; i < pins.count; i++) if (NSPointInRect(p, [self pinRect:i])) return (NSInteger)[WinFor(self).tabs indexOfObject:pins[i]];
    for (NSUInteger i = 0; i < loose.count; i++) {
        NSRect r = [self rowRect:i];
        if (NSPointInRect(p, r)) {
            if (onClose) *onClose = self.compact ? loose[i] == WinFor(self).current : p.x > NSMaxX(r) - 26;
            return (NSInteger)[WinFor(self).tabs indexOfObject:loose[i]];
        }
    }
    if (NSPointInRect(p, [self newRect])) return -2;
    return -1;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas.copy) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e {
    BOOL c = NO; NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil] close:&c];
    if (h != self.hoverRow || c != self.hoverClose) {
        self.hoverRow = h; self.hoverClose = c; self.needsDisplay = YES;
        if (self.compact) {   // narrow: the name appears as a tooltip
            VTab *t = h >= 0 && h < (NSInteger)WinFor(self).tabs.count ? WinFor(self).tabs[(NSUInteger)h] : nil;
            self.toolTip = h == -2 ? @"New tab" : t ? (c ? [NSString stringWithFormat:@"Close %@", t.title ?: @"tab"] : (t.title.length ? t.title : t.url)) : nil;
        } else self.toolTip = nil;
    }
}
- (void)mouseExited:(NSEvent *)e { self.hoverRow = -1; self.hoverClose = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    BOOL c = NO; NSInteger i = [self hit:p close:&c];
    self.dragTab = nil; self.dragging = NO; self.downAt = p;
    if (i == -2) { [WinFor(self) newTab:nil select:YES]; return; }
    if (i < 0) {   // empty sidebar: drags the window, double-click zooms it (like the title bar)
        if (e.clickCount == 2) [self.window performZoom:nil]; else [self.window performWindowDragWithEvent:e];
        return;
    }
    VTab *t = WinFor(self).tabs[(NSUInteger)i];
    if (c && !t.pinned) { [WinFor(self) closeTab:t]; return; }
    [WinFor(self) selectTab:t];
    if (!t.pinned) self.dragTab = t;
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c { return NSDragOperationCopy; }
- (void)mouseDragged:(NSEvent *)e {
    if (!self.dragTab) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    // dragged out of the sidebar: the tab's page travels (onto the bookmarks bar, another app, the Finder)
    if (p.x > NSWidth(self.bounds) + 6 || p.x < -6) {
        VTab *t = self.dragTab; self.dragTab = nil; self.dragging = NO; self.needsDisplay = YES;
        if (t.url.length && !t.isHome && ![t.url hasPrefix:@"flint:"]) BeginURLDrag(self, e, t.url, t.title, t.favicon, nil);
        return;
    }
    if (!self.dragging && fabs(p.y - self.downAt.y) < 4) return;
    self.dragging = YES;
    NSInteger n = (NSInteger)self.loose.count;
    NSInteger idx = (NSInteger)round((p.y - self.listTop) / (kRowH + 2));
    self.dropIndex = MAX(0, MIN(n, idx));
    self.needsDisplay = YES;
    [self autoscroll:e];
}
- (void)mouseUp:(NSEvent *)e {
    if (self.dragging && self.dragTab) {
        NSArray *loose = self.loose;
        NSInteger from = (NSInteger)[loose indexOfObject:self.dragTab], to = self.dropIndex;
        if (to > from) to -= 1;
        NSInteger pinCount = (NSInteger)self.pinned.count;
        if (to != from) [WinFor(self) moveTab:self.dragTab to:pinCount + to];
    }
    self.dragging = NO; self.dragTab = nil; self.needsDisplay = YES;
}
- (void)otherMouseDown:(NSEvent *)e {
    NSInteger i = [self hit:[self convertPoint:e.locationInWindow fromView:nil] close:NULL];
    if (i >= 0) [WinFor(self) closeTab:WinFor(self).tabs[(NSUInteger)i]];
}
- (void)rightMouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger i = [self hit:p close:NULL];
    if (i >= 0) [WinFor(self) tabMenu:WinFor(self).tabs[(NSUInteger)i] at:p inView:self];
}
@end

#pragma mark - New tab page ("Hearth")

@interface VHome : NSView
@property (strong) NSArray<NSDictionary *> *tiles;
@property NSInteger hover;
@property NSRect strike;
@property (strong) NSTimer *clock;
@property (strong) NSTextField *field;   // the box you type into on a new tab
- (void)reload;
@end

@implementation VHome
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)viewDidMoveToWindow {
    [self.clock invalidate]; self.clock = nil;
    if (!self.window) return;
    __weak VHome *ws = self;   // the clock ticks over each minute
    self.clock = [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *t) { ws.needsDisplay = YES; }];
}
- (void)reload {
    NSMutableArray *t = [NSMutableArray array];
    NSMutableSet *hosts = [NSMutableSet set];
    if (![Defaults() boolForKey:kHomeTopSites] || WinFor(self).isPrivate) { self.tiles = @[]; self.hover = -1; self.needsDisplay = YES; return; }
    for (NSDictionary *s in [[VHistory forProfile:WinFor(self).profile] topSites:16]) {
        NSString *h = HostOf([NSURL URLWithString:s[@"u"]]);
        if ([hosts containsObject:h]) continue; [hosts addObject:h];
        [t addObject:s]; if (t.count >= 8) break;
    }
    if (t.count < 8) for (NSDictionary *b in VBookmarks.shared.allURLs) {
        NSString *h = HostOf([NSURL URLWithString:b[@"url"]]);
        if (!h.length || [hosts containsObject:h]) continue; [hosts addObject:h];
        [t addObject:@{@"u": b[@"url"], @"ti": [b[@"name"] length] ? b[@"name"] : h}]; if (t.count >= 8) break;
    }
    self.tiles = t; self.hover = -1; self.needsDisplay = YES;
}
- (CGFloat)top { return round(MAX(48, NSHeight(self.bounds) * 0.2)); }
- (NSRect)strikeRect {
    CGFloat W = NSWidth(self.bounds), dh = [@"Monday" sizeWithAttributes:@{NSFontAttributeName: TitleFont(44, YES)}].height;
    CGFloat sw = MIN(540, W - 64);
    return NSMakeRect(round((W - sw) / 2), self.top + dh + 44, sw, 44);
}
// A real text field sits in the box: click it and type, with the same suggestions as the address bar.
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self placeField]; }
- (void)layout { [super layout]; [self placeField]; }
- (void)placeField {
    if (!self.field) {
        NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
        f.bezeled = NO; f.bordered = NO; f.drawsBackground = NO; f.focusRingType = NSFocusRingTypeNone;
        f.cell.scrollable = YES; f.cell.wraps = NO; f.usesSingleLineMode = YES;
        f.font = UIFont(14, NSFontWeightRegular); f.textColor = vText;
        f.delegate = (id<NSTextFieldDelegate>)WinFor(self);
        self.field = f; [self addSubview:f];
    }
    BOOL priv = WinFor(self).isPrivate;
    NSString *ph = priv ? @"Search privately or type an address" : [NSString stringWithFormat:@"Search %@ or type an address", Engine()[0]];
    self.field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:ph attributes:@{NSFontAttributeName: UIFont(14, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint}];
    self.field.textColor = vText;
    NSRect s = [self strikeRect];
    self.field.frame = NSMakeRect(NSMinX(s) + 42, NSMinY(s) + round((44 - 20) / 2), NSWidth(s) - 42 - 16, 20);
}
- (NSRect)tileRect:(NSUInteger)i {
    CGFloat W = NSWidth(self.bounds), tw = 96, th = 88, gap = 10;
    NSUInteger perRow = W > 560 ? 4 : 2;
    CGFloat total = perRow * tw + (perRow - 1) * gap;
    CGFloat x0 = round((W - total) / 2), y0 = NSMaxY(self.strike) + 36;
    return NSMakeRect(x0 + (i % perRow) * (tw + gap), y0 + (i / perRow) * (th + gap), tw, th);
}
- (void)drawRect:(NSRect)dirty {
    [vContentBg setFill]; NSRectFill(NSIntersectionRect(dirty, self.bounds));
    BOOL priv = WinFor(self).isPrivate;
    CGFloat W = NSWidth(self.bounds), top = self.top;
    // the day, set in a book face: calm, like the first page of something
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"EEEE";
    NSString *day = [f stringFromDate:NSDate.date];
    NSDictionary *da = @{NSFontAttributeName: TitleFont(44, YES), NSForegroundColorAttributeName: vText, NSKernAttributeName: @(-0.9)};
    NSSize ds = [day sizeWithAttributes:da];
    [day drawAtPoint:NSMakePoint(round((W - ds.width) / 2), top) withAttributes:da];
    f.dateFormat = @"d MMMM";
    NSString *sub = [f stringFromDate:NSDate.date];
    if (priv) sub = [sub stringByAppendingString:@"  ·  Private window"];
    NSDictionary *sa = @{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: vDim};
    NSSize ss = [sub sizeWithAttributes:sa];
    [sub drawAtPoint:NSMakePoint(round((W - ss.width) / 2), top + ds.height + 4) withAttributes:sa];
    // where you start typing
    self.strike = [self strikeRect];
    BOOL typing = self.field.currentEditor != nil;
    RoundRect(self.strike, 12, typing ? vPillFocus : vPill);
    ShardStroke(self.strike, 12, typing ? vLine : vSep, 1);
    NSImage *mg = Tinted(Symbol(@"magnifyingglass", 13, NSFontWeightMedium), vFaint);
    DrawImage(mg, CenterIn(mg.size, NSMakeRect(NSMinX(self.strike) + 14, NSMinY(self.strike), 20, 44)));
    if (priv) {
        NSMutableParagraphStyle *cp = [NSMutableParagraphStyle new]; cp.alignment = NSTextAlignmentCenter; cp.lineSpacing = 3;
        [@"Nothing from this window is kept: no history, and cookies and site data disappear when you close it. Extensions don't run here."
            drawInRect:NSMakeRect(round((W - 400) / 2), NSMaxY(self.strike) + 36, 400, 60)
            withAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint, NSParagraphStyleAttributeName: cp}];
        return;
    }
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        NSDictionary *t = self.tiles[i]; NSRect r = [self tileRect:i];
        BOOL hov = (NSInteger)i == self.hover;
        if (hov) RoundRect(r, 12, vHover);
        NSRect well = NSMakeRect(NSMidX(r) - 22, NSMinY(r) + 10, 44, 44);
        RoundRect(well, 12, hov ? vActive : vPill);
        NSImage *ic = [VFavicons.shared iconForURL:t[@"u"]];
        if (ic) DrawImage(ic, CenterIn(NSMakeSize(22, 22), well));
        else {
            NSString *L = [[t[@"ti"] ?: @"?" substringToIndex:MIN(1, [t[@"ti"] length])] uppercaseString];
            NSDictionary *la = @{NSFontAttributeName: TitleFont(18, YES), NSForegroundColorAttributeName: vDim};
            NSSize ls = [L sizeWithAttributes:la];
            [L drawAtPoint:NSMakePoint(NSMidX(well) - ls.width / 2, NSMidY(well) - ls.height / 2) withAttributes:la];
        }
        NSString *name = t[@"ti"] ?: @"";
        if ([name hasSuffix:@".com"]) name = [name substringToIndex:name.length - 4];
        [name drawInRect:NSMakeRect(NSMinX(r) + 6, NSMinY(r) + 62, NSWidth(r) - 12, 18)
          withAttributes:@{NSFontAttributeName: UIFont(12, NSFontWeightRegular), NSForegroundColorAttributeName: hov ? vText : vDim, NSParagraphStyleAttributeName: ps}];
    }
}
- (NSInteger)tileAt:(NSPoint)p { for (NSUInteger i = 0; i < self.tiles.count; i++) if (NSPointInRect(p, [self tileRect:i])) return (NSInteger)i; return -1; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas.copy) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e { NSInteger h = [self tileAt:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != self.hover) { self.hover = h; self.needsDisplay = YES; } }
- (void)mouseExited:(NSEvent *)e { self.hover = -1; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)e {
    NSInteger i = [self tileAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i >= 0) [WinFor(self) openURL:[NSURL URLWithString:self.tiles[(NSUInteger)i][@"u"]] newTab:(e.modifierFlags & NSEventModifierFlagCommand) != 0];
    else [self.window makeFirstResponder:self.field];   // anywhere on the page: start typing
}
@end

#pragma mark - Rail dock: the foot of the sidebar

@interface VRailDock : NSView
@end
@implementation VRailDock
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) return nil;
    NSArray *items = @[@[@"clock.arrow.circlepath", @"History (⌘Y)", @"showHistory:"], @[@"books.vertical", @"Bookmarks (⌥⌘B)", @"showBookmarks:"],
                       @[@"tray.and.arrow.down", @"Downloads (⌥⌘L)", @"showDownloadManager:"], @[@"eye.slash", @"New private window (⇧⌘N)", @"newPrivateWindow:"],
                       @[@"gearshape", @"Settings (⌘,)", @"showSettings:"]];
    for (NSArray *it in items) {
        VButton *b = [VButton symbol:it[0] size:13 tip:it[1] target:nil action:NSSelectorFromString(it[2])];
        [self addSubview:b];
    }
    return self;
}
- (void)resizeSubviewsWithOldSize:(NSSize)o {
    NSUInteger n = self.subviews.count; if (!n) return;
    if (NSWidth(self.bounds) < 100) {   // narrow sidebar: the buttons stack
        for (NSUInteger i = 0; i < n; i++) self.subviews[i].frame = NSMakeRect(round((NSWidth(self.bounds) - 32) / 2), 8 + i * 32, 32, 30);
        return;
    }
    CGFloat w = MIN(36, (NSWidth(self.bounds) - 16) / n), gapTotal = NSWidth(self.bounds) - 16 - w * n, gap = n > 1 ? gapTotal / (n - 1) : 0;
    for (NSUInteger i = 0; i < n; i++) self.subviews[i].frame = NSMakeRect(round(8 + i * (w + gap)), 6, w, 30);
}
- (void)drawRect:(NSRect)dirty {
    [vBg setFill]; NSRectFill(NSIntersectionRect(dirty, self.bounds));
    [vSep setFill]; NSRectFill(NSMakeRect(12, 0, NSWidth(self.bounds) - 24, 1));
}
- (void)mouseDown:(NSEvent *)e { [self.window performWindowDragWithEvent:e]; }
@end

#pragma mark - Sidebar resize handle

// Drag the sidebar's edge to resize it: 180–340 wide, or narrower than ~120 and it snaps to a column of icons.
static const CGFloat kSideCompact = 56, kSideMin = 180, kSideMax = 340;
static CGFloat SidebarWidth(void) {
    CGFloat w = [Defaults() doubleForKey:kSidebarW] ?: 228;
    return w < 100 ? kSideCompact : MAX(kSideMin, MIN(kSideMax, w));
}
@interface VSideHandle : NSView
@property BOOL onRight;
@end
@implementation VSideHandle
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor]; }
- (void)mouseDown:(NSEvent *)e {
    if (e.clickCount == 2) {   // double-click: between icons and full width
        [Defaults() setDouble:SidebarWidth() <= kSideCompact ? 228 : kSideCompact forKey:kSidebarW];
        [WinFor(self) layout]; return;
    }
}
- (void)mouseDragged:(NSEvent *)e {
    NSView *root = self.superview;
    CGFloat x = [root convertPoint:e.locationInWindow fromView:nil].x;
    CGFloat w = self.onRight ? NSWidth(root.bounds) - x : x;
    CGFloat snapped = w < 120 ? kSideCompact : MAX(kSideMin, MIN(kSideMax, w));
    if (fabs(snapped - SidebarWidth()) < 0.5) return;
    [Defaults() setDouble:snapped forKey:kSidebarW];
    [WinFor(self) layout];
}
@end

#pragma mark - Find in page

@interface VFindBar : NSView
@property (strong) NSTextField *field;
@property (strong) NSTextField *result;
@end

@implementation VFindBar
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) return nil;
    self.wantsLayer = YES;
    self.layer.backgroundColor = vCard.CGColor;
    FacetView(self, 10, vLine);
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 9, 170, 18)];
    f.bezeled = NO; f.bordered = NO; f.drawsBackground = NO; f.focusRingType = NSFocusRingTypeNone;
    f.font = UIFont(13, NSFontWeightRegular); f.textColor = vText;
    f.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"Find on page" attributes:@{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint}];
    f.target = WinFor(self); f.action = @selector(findNext:);
    f.delegate = (id<NSTextFieldDelegate>)WinFor(self);
    self.field = f; [self addSubview:f];
    self.result = [NSTextField labelWithString:@""];
    self.result.font = UIFont(11.5, NSFontWeightRegular); self.result.textColor = vFaint;
    self.result.frame = NSMakeRect(184, 10, 60, 16); [self addSubview:self.result];
    VButton *prev = [VButton symbol:@"chevron.up" size:11 tip:@"Previous (⇧⌘G)" target:WinFor(self) action:@selector(findPrevious:)];
    VButton *next = [VButton symbol:@"chevron.down" size:11 tip:@"Next (⌘G)" target:WinFor(self) action:@selector(findNext:)];
    VButton *done = [VButton symbol:@"xmark" size:10 tip:@"Close (esc)" target:WinFor(self) action:@selector(closeFind:)];
    prev.frame = NSMakeRect(244, 4, 26, 28); next.frame = NSMakeRect(270, 4, 26, 28); done.frame = NSMakeRect(298, 4, 26, 28);
    [self addSubview:prev]; [self addSubview:next]; [self addSubview:done];
    return self;
}
@end

static void *kDLProgress = &kDLProgress;

@implementation VDownloads
+ (instancetype)shared {
    static VDownloads *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [VDownloads new]; s.items = [NSMutableArray array];
        for (NSDictionary *d in [Defaults() arrayForKey:@"downloads"] ?: @[]) {
            VDownload *x = [VDownload new]; x.name = d[@"name"]; x.path = d[@"path"]; x.url = d[@"url"]; x.total = [d[@"total"] longLongValue]; x.received = x.total;
            x.state = [d[@"state"] isEqual:@"done"] ? @"done" : [d[@"state"] isEqual:@"cancelled"] ? @"cancelled" : @"failed"; x.started = [d[@"t"] doubleValue];
            x.ended = [d[@"end"] doubleValue]; x.ident = d[@"id"] ?: NSUUID.UUID.UUIDString; x.kind = d[@"kind"] ?: @"webkit";
            x.error = d[@"err"]; x.peak = [d[@"peak"] doubleValue];
            // an unfinished accelerated download comes back paused, slices and all, ready to continue
            if ([x.kind isEqual:@"accel"] && ![x.state isEqual:@"done"] && [d[@"segs"] isKindOfClass:NSArray.class] && [NSFileManager.defaultManager fileExistsAtPath:d[@"part"] ?: @""]) {
                x.partPath = d[@"part"]; x.referer = d[@"ref"]; x.ua = d[@"ua"]; x.resumable = [d[@"res"] boolValue];
                x.segs = [NSMutableArray array]; int64_t got = 0;
                for (NSDictionary *g in d[@"segs"]) { NSMutableDictionary *m = [g mutableCopy]; m[@"tries"] = @0; [x.segs addObject:m]; got += [g[@"g"] longLongValue]; }
                x.received = got; x.state = [d[@"state"] isEqual:@"failed"] ? @"failed" : @"paused";
            }
            [s.items addObject:x];
        }
    });
    return s;
}
- (void)save {
    NSMutableArray *a = [NSMutableArray array];
    for (VDownload *x in self.items) {
        if (a.count >= 300 || x.isPrivate) continue;   // private-window downloads leave no record
        NSMutableDictionary *d = [@{@"name": x.name ?: @"", @"path": x.path ?: @"", @"url": x.url ?: @"", @"total": @(x.total), @"state": x.state ?: @"failed",
                                    @"t": @(x.started), @"end": @(x.ended), @"id": x.ident ?: NSUUID.UUID.UUIDString, @"kind": x.kind ?: @"webkit", @"peak": @(x.peak)} mutableCopy];
        if (x.error) d[@"err"] = x.error;
        if ([x.kind isEqual:@"accel"] && ![x.state isEqual:@"done"] && x.partPath) {
            NSMutableArray *segs = [NSMutableArray array];
            for (NSDictionary *g in x.segs.copy) [segs addObject:@{@"s": g[@"s"] ?: @0, @"e": g[@"e"] ?: @-1, @"g": g[@"g"] ?: @0}];
            d[@"segs"] = segs; d[@"part"] = x.partPath; d[@"res"] = @(x.resumable);
            if (x.referer) d[@"ref"] = x.referer;
            if (x.ua) d[@"ua"] = x.ua;
        }
        [a addObject:d];
    }
    [Defaults() setObject:a forKey:@"downloads"];
}
- (VDownload *)find:(WKDownload *)d { for (VDownload *x in self.items) if (x.wk == d) return x; return nil; }
- (VDownload *)byId:(NSString *)ident { for (VDownload *x in self.items.copy) if ([x.ident isEqualToString:ident]) return x; return nil; }
- (VDownload *)startFor:(WKDownload *)d dest:(NSURL *)dest {
    VDownload *x = [VDownload new];
    x.wk = d; x.view = d.webView; x.name = dest.lastPathComponent; x.path = dest.path; x.url = d.originalRequest.URL.absoluteString;
    x.ident = NSUUID.UUID.UUIDString; x.kind = @"webkit";
    x.state = @"running"; x.started = x.lastTick = NSDate.date.timeIntervalSince1970;
    [self.items insertObject:x atIndex:0];
    [d.progress addObserver:self forKeyPath:@"completedUnitCount" options:0 context:kDLProgress];
    objc_setAssociatedObject(d, "observed", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self changed];
    return x;
}
- (void)stopObserving:(WKDownload *)d {
    if (objc_getAssociatedObject(d, "observed")) { @try { [d.progress removeObserver:self forKeyPath:@"completedUnitCount" context:kDLProgress]; } @catch (NSException *e) {} objc_setAssociatedObject(d, "observed", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}
- (void)observeValueForKeyPath:(NSString *)k ofObject:(NSProgress *)p change:(NSDictionary *)c context:(void *)ctx {
    if (ctx != kDLProgress) { [super observeValueForKeyPath:k ofObject:p change:c context:ctx]; return; }
    int64_t done = p.completedUnitCount, total = p.totalUnitCount;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (VDownload *x in self.items) if (x.wk && x.wk.progress == p) {
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            x.received = done; x.total = total > 0 ? total : 0;
            if (now - x.lastTick >= 0.5) { double sp = (done - x.lastBytes) / (now - x.lastTick); x.speed = x.speed > 0 ? x.speed * 0.6 + sp * 0.4 : sp; x.lastTick = now; x.lastBytes = done; }
        }
        [self changed];
    });
}
- (void)finished:(WKDownload *)d {
    VDownload *x = [self find:d]; [self stopObserving:d];
    if (x) { x.ended = NSDate.date.timeIntervalSince1970; x.state = @"done"; x.total = x.received = MAX(x.received, [[NSFileManager.defaultManager attributesOfItemAtPath:x.path error:nil] fileSize]); }
    [self save]; [self changed];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 61 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ for (VWindow *w in gWindows) [w.toolbar layoutBar]; });
    if (x) [gWin showToast:[NSString stringWithFormat:@"Downloaded %@", x.name]];
    // bounce the Downloads stack in the Dock, like Safari
    if (x.path) [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.apple.DownloadFileFinished" object:x.path];
}
- (void)failed:(WKDownload *)d resume:(NSData *)r {
    VDownload *x = [self find:d]; [self stopObserving:d];
    if (x && ![x.state isEqual:@"cancelled"]) { x.state = @"failed"; x.resume = r; }
    if (x) x.ended = NSDate.date.timeIntervalSince1970;
    [self save]; [self changed];
}
// The toolbar's Downloads button appears while something downloads and for a minute after, then steps aside.
- (BOOL)worthShowing {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (VDownload *x in self.items) if ([@[@"running", @"queued"] containsObject:x.state ?: @""] || (x.ended > 0 && now - x.ended < 60)) return YES;
    return NO;
}
- (double)activeProgress {
    int64_t got = 0, total = 0; BOOL any = NO;
    for (VDownload *x in self.items) if ([x.state isEqual:@"running"]) { any = YES; got += x.received; total += x.total; }
    if (!any) return -1;
    return total > 0 ? (double)got / total : 0;
}
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:@"FlintDownloadsChanged" object:nil]; }
@end

static NSPopover *gDLPop;   // the toolbar's quick list
static NSString *Bytes(int64_t b) { return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleFile]; }

#pragma mark The panel

@interface VDownloadsView : NSView
@property NSInteger hover;
@end
@implementation VDownloadsView {
    NSTrackingArea *_ta;
}
static const CGFloat kDLRow = 52, kDLHead = 40, kDLFoot = 40;
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) return nil;
    self.hover = -1;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:@"FlintDownloadsChanged" object:nil];
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh { self.needsDisplay = YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_ta) [self removeTrackingArea:_ta];
    _ta = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_ta];
}
- (NSArray<VDownload *> *)rows { NSArray *a = VDownloads.shared.items; return a.count > 8 ? [a subarrayWithRange:NSMakeRange(0, 8)] : a; }
- (NSInteger)rowAt:(NSPoint)p { NSInteger i = (NSInteger)floor((p.y - kDLHead) / kDLRow); return (p.y >= kDLHead && i >= 0 && i < (NSInteger)self.rows.count) ? i : -1; }
- (NSRect)actionRect:(NSInteger)i { return NSMakeRect(NSWidth(self.bounds) - 44, kDLHead + i * kDLRow + 12, 28, 28); }
- (void)mouseMoved:(NSEvent *)e { NSInteger h = [self rowAt:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != self.hover) { self.hover = h; self.needsDisplay = YES; } }
- (void)mouseExited:(NSEvent *)e { self.hover = -1; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
    CGFloat W = NSWidth(self.bounds);
    [@"Downloads" drawAtPoint:NSMakePoint(16, 12) withAttributes:@{NSFontAttributeName: UIFont(13, NSFontWeightSemibold), NSForegroundColorAttributeName: vText}];
    NSArray *rows = self.rows;
    if (!rows.count) [@"Nothing downloaded yet" drawAtPoint:NSMakePoint(16, kDLHead + 14) withAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint}];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingMiddle;
    for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
        VDownload *x = rows[(NSUInteger)i];
        NSRect r = NSMakeRect(8, kDLHead + i * kDLRow, W - 16, kDLRow - 2);
        if (i == self.hover) RoundRect(r, 8, vHover);
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:[NSFileManager.defaultManager fileExistsAtPath:x.path] ? x.path : @"/System/Library"];
        if (![NSFileManager.defaultManager fileExistsAtPath:x.path]) icon = [NSWorkspace.sharedWorkspace iconForContentType:[UTType typeWithFilenameExtension:x.name.pathExtension ?: @""] ?: UTTypeData];
        [icon drawInRect:NSMakeRect(18, NSMinY(r) + 9, 32, 32) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        CGFloat tw = W - 60 - 56;
        [x.name drawInRect:NSMakeRect(60, NSMinY(r) + 8, tw, 17) withAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightMedium), NSForegroundColorAttributeName: vText, NSParagraphStyleAttributeName: ps}];
        NSString *line; NSColor *lc = vFaint;
        if ([x.state isEqual:@"running"]) {
            NSString *rate = x.speed > 0 ? [NSString stringWithFormat:@" — %@/s", Bytes((int64_t)x.speed)] : @"";
            NSString *left = (x.speed > 0 && x.total > x.received) ? [NSString stringWithFormat:@", %.0fs left", (x.total - x.received) / x.speed] : @"";
            line = x.total > 0 ? [NSString stringWithFormat:@"%@ of %@%@%@", Bytes(x.received), Bytes(x.total), rate, left] : [NSString stringWithFormat:@"%@%@", Bytes(x.received), rate];
            double f = x.total > 0 ? (double)x.received / x.total : 0;
            RoundRect(NSMakeRect(60, NSMinY(r) + 42, tw, 3), 1.5, vLine);
            RoundRect(NSMakeRect(60, NSMinY(r) + 42, MAX(3, tw * f), 3), 1.5, vAccent);
        } else if ([x.state isEqual:@"done"]) {
            line = [NSFileManager.defaultManager fileExistsAtPath:x.path] ? Bytes(x.total) : @"Moved or deleted";
        } else { line = [x.state isEqual:@"cancelled"] ? @"Cancelled" : @"Failed"; lc = [x.state isEqual:@"failed"] ? Hex(0xe5737a) : vFaint; }
        [line drawInRect:NSMakeRect(60, NSMinY(r) + 25, tw, 15) withAttributes:@{NSFontAttributeName: UIFont(11.5, NSFontWeightRegular), NSForegroundColorAttributeName: lc, NSParagraphStyleAttributeName: ps}];
        NSString *sym = [x.state isEqual:@"running"] ? @"xmark.circle.fill" : [x.state isEqual:@"done"] ? @"magnifyingglass.circle.fill" : @"arrow.clockwise.circle.fill";
        NSImage *b = Tinted(Symbol(sym, 17, NSFontWeightRegular), i == self.hover ? vText : vDim);
        DrawImage(b, CenterIn(b.size, [self actionRect:i]));
    }
    CGFloat fy = NSHeight(self.bounds) - kDLFoot;
    [vSep setFill]; NSRectFill(NSMakeRect(0, fy, W, 1));
    [@"Download Manager" drawAtPoint:NSMakePoint(16, fy + 12) withAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightRegular), NSForegroundColorAttributeName: vAccent}];
    NSString *clr = @"Clear";
    NSSize cs = [clr sizeWithAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightRegular)}];
    [clr drawAtPoint:NSMakePoint(W - 16 - cs.width, fy + 12) withAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightRegular), NSForegroundColorAttributeName: vDim}];
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat fy = NSHeight(self.bounds) - kDLFoot;
    if (p.y > fy) {
        if (p.x < NSWidth(self.bounds) / 2) { [gDLPop close]; [gWin showDownloadManager:nil]; }
        else { [VDownloads.shared.items filterUsingPredicate:[NSPredicate predicateWithFormat:@"state == 'running'"]]; [VDownloads.shared save]; self.needsDisplay = YES; [NSNotificationCenter.defaultCenter postNotificationName:@"FlintDownloadsChanged" object:nil]; }
        return;
    }
    NSInteger i = [self rowAt:p]; if (i < 0) return;
    VDownload *x = self.rows[(NSUInteger)i];
    BOOL onAction = NSPointInRect(p, NSInsetRect([self actionRect:i], -6, -6));
    if ([x.state isEqual:@"running"]) {
        if (onAction) { x.state = @"cancelled"; [x.wk cancel:nil]; [VDownloads.shared save]; self.needsDisplay = YES; }
    } else if ([x.state isEqual:@"done"]) {
        if (onAction || ![NSFileManager.defaultManager fileExistsAtPath:x.path]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:x.path]]];
        else [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:x.path]];
    } else if (onAction) {
        // retry: resume where it stopped when WebKit kept the data, otherwise start again
        [VDownloads.shared.items removeObject:x];
        WKWebView *v = x.view ?: gWin.current.web.web;
        if (x.resume && v) [v resumeDownloadFromResumeData:x.resume completionHandler:^(WKDownload *d) { d.delegate = (id<WKDownloadDelegate>)v.navigationDelegate; }];
        else if (x.url) [gWin.current.web download:x.url];
        [VDownloads.shared save]; self.needsDisplay = YES;
    }
}
@end

@implementation VWindow (Downloads)
- (void)showDownloads:(id)s {
    NSPopover *pop = gDLPop;
    if (pop.shown) { [pop close]; return; }
    NSUInteger n = MIN((NSUInteger)8, VDownloads.shared.items.count);
    CGFloat h = kDLHead + MAX(1, n) * kDLRow + kDLFoot + 6;
    VDownloadsView *v = [[VDownloadsView alloc] initWithFrame:NSMakeRect(0, 0, 380, h)];
    NSViewController *vc = [NSViewController new]; vc.view = v;
    pop = gDLPop = [NSPopover new]; pop.contentViewController = vc; pop.contentSize = v.frame.size;
    pop.behavior = NSPopoverBehaviorTransient; pop.appearance = ThemeAppearance();
    NSView *at = self.toolbar.dlBtn.hidden ? self.toolbar.menuBtn : self.toolbar.dlBtn;
    [pop showRelativeToRect:at.bounds ofView:at preferredEdge:NSRectEdgeMaxY];
}
@end

#pragma mark - Download accelerator (Flint's own downloader, in the spirit of Internet Download Manager)

// A file the server can send in pieces (HTTP byte ranges) is fetched over several connections at once, each
// carrying one slice, and written straight into place in a .flintpart file. When a slice finishes early, the
// biggest slice still running is split in two and a new connection takes the second half, so the fast
// connections keep working to the end. Pausing keeps every slice's progress, also across quitting Flint.
// The site's cookies, user agent and referrer go with every request, so signed-in downloads work; anything
// Flint can't fetch itself (a form post, a one-time link that refuses a second request) falls back to WebKit's
// own downloader. Finished files get macOS's "downloaded from the internet" flag, like Safari's.

static NSString *const kDLConns  = @"dlConnections";   // slices per download, 1–16
static NSString *const kDLActive = @"dlMaxActive";     // downloads at once; the rest wait in line
static NSString *const kDLLimit  = @"dlSpeedLimit";    // KB/s for all downloads together, 0 = no limit

static const int64_t kMinSlice = 1 << 20;   // never split below 1 MB

@interface FAccel : NSObject <NSURLSessionDataDelegate>
+ (instancetype)shared;
- (void)downloadURL:(NSURL *)u name:(NSString *)name referer:(NSString *)ref view:(WKWebView *)v private:(BOOL)priv;
- (void)pause:(VDownload *)x;
- (void)resume:(VDownload *)x;
- (void)cancel:(VDownload *)x;
- (void)pauseAll;
- (void)resumeAll;
- (int64_t)currentSpeed;
@end

static NSString *UniquePath(NSString *dir, NSString *name) {
    NSString *p = [dir stringByAppendingPathComponent:name];
    for (int n = 1; [NSFileManager.defaultManager fileExistsAtPath:p] || [NSFileManager.defaultManager fileExistsAtPath:[p stringByAppendingString:@".flintpart"]]; n++)
        p = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d%@", name.stringByDeletingPathExtension, n, name.pathExtension.length ? [@"." stringByAppendingString:name.pathExtension] : @""]];
    return p;
}

// a cookie belongs with a request when its domain, path and secure flag fit the URL
static NSString *CookieHeader(NSArray<NSHTTPCookie *> *all, NSURL *u) {
    NSString *host = u.host.lowercaseString ?: @"", *path = u.path.length ? u.path : @"/";
    NSMutableArray *pick = [NSMutableArray array];
    for (NSHTTPCookie *c in all) {
        NSString *d = c.domain.lowercaseString;
        BOOL dom = [d hasPrefix:@"."] ? ([host hasSuffix:d] || [host isEqualToString:[d substringFromIndex:1]]) : [host isEqualToString:d];
        if (!dom || ![path hasPrefix:c.path ?: @"/"] || (c.isSecure && ![u.scheme isEqualToString:@"https"])) continue;
        if (c.expiresDate && c.expiresDate.timeIntervalSinceNow < 0) continue;
        [pick addObject:c];
    }
    return [NSHTTPCookie requestHeaderFieldsWithCookies:pick][@"Cookie"];
}

static void MarkQuarantined(NSString *path, NSString *from) {
    NSString *q = [NSString stringWithFormat:@"0083;%08lx;Flint;%@", (unsigned long)time(NULL), NSUUID.UUID.UUIDString];
    setxattr(path.fileSystemRepresentation, "com.apple.quarantine", q.UTF8String, strlen(q.UTF8String), 0, 0);
    if (from.length) {   // "where from", as Finder's Get Info shows it
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:@[from] format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if (plist) setxattr(path.fileSystemRepresentation, "com.apple.metadata:kMDItemWhereFroms", plist.bytes, plist.length, 0, 0);
    }
}

@implementation FAccel {
    NSURLSession *_session;
    NSOperationQueue *_q;                 // every slice's bookkeeping happens here, one thing at a time
    int64_t _windowBytes; BOOL _held;     // speed limit: bytes in this half second, and whether connections are on hold
    int64_t _speed;                       // all downloads together, bytes/s
}

+ (instancetype)shared {
    static FAccel *a; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [FAccel new]; [a setUp]; });
    return a;
}
- (void)setUp {
    _q = [NSOperationQueue new]; _q.maxConcurrentOperationCount = 1; _q.qualityOfService = NSQualityOfServiceUtility;
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.HTTPMaximumConnectionsPerHost = 32; c.timeoutIntervalForRequest = 40; c.timeoutIntervalForResource = 7 * 24 * 3600;
    c.HTTPShouldSetCookies = NO; c.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever; c.URLCache = nil;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:_q];
    [Defaults() registerDefaults:@{kDLConns: @8, kDLActive: @3, kDLLimit: @0}];
    __weak FAccel *ws = self;
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { FAccel *me = ws; if (me) [me->_q addOperationWithBlock:^{ [me tick]; }]; }];
}

#pragma mark Starting

- (void)downloadURL:(NSURL *)u name:(NSString *)name referer:(NSString *)ref view:(WKWebView *)v private:(BOOL)priv {
    VWindow *w = WinOfWeb(v) ?: gWin;
    NSString *file = name.length ? name : (u.lastPathComponent.length > 1 ? u.lastPathComponent.stringByRemovingPercentEncoding : nil) ?: @"download";
    file = [[file stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    VDownload *x = [VDownload new];
    x.ident = NSUUID.UUID.UUIDString; x.kind = @"accel"; x.url = u.absoluteString; x.referer = ref; x.view = v; x.isPrivate = priv;
    x.path = UniquePath(w.downloadFolder.path, file); x.name = x.path.lastPathComponent; x.partPath = [x.path stringByAppendingString:@".flintpart"];
    NSString *ua = nil; @try { ua = [v valueForKey:@"_userAgent"]; } @catch (NSException *e) {}
    x.ua = ua.length ? ua : @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15";
    x.state = @"queued"; x.started = x.lastTick = NSDate.date.timeIntervalSince1970;
    x.segs = [NSMutableArray arrayWithObject:[@{@"s": @0, @"e": @-1, @"g": @0, @"tries": @0} mutableCopy]];
    x.tasks = [NSMutableDictionary dictionary];
    [VDownloads.shared.items insertObject:x atIndex:0];
    [VDownloads.shared changed];
    [w showToast:[NSString stringWithFormat:@"Downloading %@…", x.name]];
    for (VWindow *each in gWindows) [each.toolbar layoutBar];
    [self withCookiesFor:x then:^{ [self->_q addOperationWithBlock:^{ [self schedule]; }]; }];
}

// cookies are read fresh each time a download starts or resumes, from the window's own website data
- (void)withCookiesFor:(VDownload *)x then:(void (^)(void))go {
    WKWebsiteDataStore *store = x.view.configuration.websiteDataStore ?: WKWebsiteDataStore.defaultDataStore;
    [store.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *all) { x.cookie = CookieHeader(all, [NSURL URLWithString:x.url]); go(); }];
}

- (NSURLRequest *)requestFor:(VDownload *)x from:(int64_t)s to:(int64_t)e {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:x.url]];
    [r setValue:x.ua forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [r setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];   // compressed bodies can't be split into byte ranges
    if (x.referer.length) [r setValue:x.referer forHTTPHeaderField:@"Referer"];
    if (x.cookie.length) [r setValue:x.cookie forHTTPHeaderField:@"Cookie"];
    // always ask for a range (the opening request asks for "bytes=0-"): a 206 answer is how we learn the server does slices
    [r setValue:[NSString stringWithFormat:@"bytes=%lld-%@", s, e >= 0 ? @(e).stringValue : @""] forHTTPHeaderField:@"Range"];
    return r;
}

// in the line: start downloads while fewer than the allowed number are running
- (void)schedule {
    NSInteger running = 0, allowed = MAX(1, [Defaults() integerForKey:kDLActive]);
    NSArray *items = VDownloads.shared.items.copy;
    for (VDownload *x in items) if ([x.kind isEqual:@"accel"] && [x.state isEqual:@"running"]) running++;
    for (VDownload *x in items.reverseObjectEnumerator) {   // oldest first
        if (running >= allowed) break;
        if (![x.kind isEqual:@"accel"] || ![x.state isEqual:@"queued"]) continue;
        [self begin:x]; running++;
    }
}

- (void)begin:(VDownload *)x {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:x.partPath]) [fm createFileAtPath:x.partPath contents:nil attributes:nil];
    x.fh = [NSFileHandle fileHandleForUpdatingAtPath:x.partPath];
    if (!x.fh) { [self fail:x why:@"Couldn't write to the download folder"]; return; }
    if (!x.tasks) x.tasks = [NSMutableDictionary dictionary];
    x.state = @"running"; x.error = nil; x.lastTick = NSDate.date.timeIntervalSince1970; x.lastBytes = x.received;
    for (NSUInteger i = 0; i < x.segs.count; i++) if (![self segDone:x.segs[i]]) [self startSeg:x index:i];
    if ([self allDone:x]) [self finish:x];
    [self changedMain];
}

- (BOOL)segDone:(NSDictionary *)g { int64_t e = [g[@"e"] longLongValue]; return [g[@"done"] boolValue] || (e >= 0 && [g[@"s"] longLongValue] + [g[@"g"] longLongValue] > e); }
- (BOOL)allDone:(VDownload *)x { for (NSDictionary *g in x.segs) if (![self segDone:g]) return NO; return x.segs.count > 0; }

- (void)startSeg:(VDownload *)x index:(NSUInteger)i {
    NSMutableDictionary *g = x.segs[i];
    int64_t from = [g[@"s"] longLongValue] + [g[@"g"] longLongValue], to = [g[@"e"] longLongValue];
    NSURLSessionDataTask *t = [_session dataTaskWithRequest:[self requestFor:x from:from to:to]];
    t.taskDescription = [NSString stringWithFormat:@"%@#%lu", x.ident, (unsigned long)i];
    x.tasks[@(i)] = t; x.conns = (NSInteger)x.tasks.count;
    if (_held) [t suspend]; else [t resume];
}

#pragma mark Receiving

- (VDownload *)owner:(NSURLSessionTask *)t index:(NSUInteger *)idx {
    NSArray *p = [t.taskDescription componentsSeparatedByString:@"#"]; if (p.count != 2) return nil;
    VDownload *x = [VDownloads.shared byId:p[0]];
    NSUInteger i = (NSUInteger)[p[1] integerValue];
    if (!x || i >= x.segs.count || x.tasks[@(i)] != t) return nil;   // a connection we've since replaced or stopped
    if (idx) *idx = i;
    return x;
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))done {
    NSUInteger i = 0; VDownload *x = [self owner:t index:&i];
    if (!x) { done(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *h = [r isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)r : nil;
    NSMutableDictionary *g = x.segs[i];
    int64_t from = [g[@"s"] longLongValue] + [g[@"g"] longLongValue];
    NSInteger code = h.statusCode;
    if (code == 206) {
        // "bytes a-b/total": the server sends slices
        NSString *cr = [h valueForHTTPHeaderField:@"Content-Range"] ?: @"";
        NSRange slash = [cr rangeOfString:@"/"];
        int64_t total = slash.location != NSNotFound ? [[cr substringFromIndex:slash.location + 1] longLongValue] : 0;
        if (total > 0 && x.total <= 0) x.total = total;
        x.resumable = YES;
        if (x.segs.count == 1 && [g[@"e"] longLongValue] < 0 && x.total > 0) [self splitFirst:x];   // the opening request: now cut the file into slices
        done(NSURLSessionResponseAllow); return;
    }
    if (code == 200) {
        if (from == 0) {   // the whole file in one stream (the server doesn't do slices, or the size is unknown)
            x.resumable = NO;
            if (h.expectedContentLength > 0) { x.total = h.expectedContentLength; g[@"e"] = @(x.total - 1); }
            done(NSURLSessionResponseAllow); return;
        }
        // asked for a later slice but got the whole file: start over as one stream
        done(NSURLSessionResponseCancel);
        [self restartWhole:x];
        return;
    }
    done(NSURLSessionResponseCancel);
    if ((code == 401 || code == 403 || code == 405 || code >= 400) && x.received == 0) { [self handBackToWebKit:x why:[NSString stringWithFormat:@"HTTP %ld", (long)code]]; return; }
    [self retry:x index:i why:[NSString stringWithFormat:@"The server answered %ld", (long)code]];
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
    NSUInteger i = 0; VDownload *x = [self owner:t index:&i]; if (!x || ![x.state isEqual:@"running"]) return;
    NSMutableDictionary *g = x.segs[i];
    int64_t at = [g[@"s"] longLongValue] + [g[@"g"] longLongValue], e = [g[@"e"] longLongValue];
    NSData *d = data;
    if (e >= 0) {   // this slice may have been shortened (split) since it started: never write past its end
        int64_t room = e - at + 1;
        if (room <= 0) { [t cancel]; return; }
        if ((int64_t)d.length > room) d = [d subdataWithRange:NSMakeRange(0, (NSUInteger)room)];
    }
    @try { [x.fh seekToFileOffset:(unsigned long long)at]; [x.fh writeData:d]; }
    @catch (NSException *ex) { [self fail:x why:@"The disk refused the data (full?)"]; return; }
    g[@"g"] = @([g[@"g"] longLongValue] + (int64_t)d.length);
    x.received += (int64_t)d.length;
    _windowBytes += (int64_t)d.length;
    if (e >= 0 && [self segDone:g]) { g[@"done"] = @YES; [t cancel]; }
    int64_t limit = [Defaults() integerForKey:kDLLimit] * 1024;
    if (limit > 0 && !_held && _windowBytes > limit / 2) [self hold:YES];   // over this half second's share: wait for the next
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)err {
    NSUInteger i = 0; VDownload *x = [self owner:t index:&i]; if (!x) return;
    [x.tasks removeObjectForKey:@(i)]; x.conns = (NSInteger)x.tasks.count;
    NSMutableDictionary *g = x.segs[i];
    if (!err && [g[@"e"] longLongValue] < 0) g[@"done"] = @YES;   // a stream of unknown length: ending cleanly means complete
    if (!err && x.total > 0 && [g[@"e"] longLongValue] >= 0 && ![self segDone:g]) err = [NSError errorWithDomain:@"flint" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The connection closed early"}];
    if ([self segDone:g]) { [self sliceFinished:x]; return; }
    if (err.code == NSURLErrorCancelled) return;   // paused, cancelled, or replaced
    if (![x.state isEqual:@"running"]) return;
    [self retry:x index:i why:err.localizedDescription];
}

#pragma mark Slices

// The first response told us the size: give the first connection the opening slice and start the rest.
- (void)splitFirst:(VDownload *)x {
    NSInteger n = MAX(1, MIN(16, [Defaults() integerForKey:kDLConns]));
    int64_t total = x.total, slice = MAX(kMinSlice, total / n);
    n = MAX(1, (NSInteger)MIN((int64_t)n, (total + slice - 1) / slice));
    x.segs[0][@"e"] = @(MIN(total, slice) - 1);
    for (NSInteger k = 1; k < n; k++) {
        int64_t s = k * slice, e = k == n - 1 ? total - 1 : (k + 1) * slice - 1;
        if (s >= total) break;
        [x.segs addObject:[@{@"s": @(s), @"e": @(e), @"g": @0, @"tries": @0} mutableCopy]];
        [self startSeg:x index:x.segs.count - 1];
    }
}

// A connection finished its slice: the download is complete, or it takes over half of the biggest slice left.
- (void)sliceFinished:(VDownload *)x {
    if ([self allDone:x]) { [self finish:x]; return; }
    if (!x.resumable || ![x.state isEqual:@"running"]) return;
    NSInteger maxConns = MAX(1, MIN(16, [Defaults() integerForKey:kDLConns]));
    while (x.tasks.count < (NSUInteger)maxConns) {
        NSUInteger best = NSNotFound; int64_t bestLeft = 0;
        for (NSUInteger k = 0; k < x.segs.count; k++) {
            NSDictionary *g = x.segs[k]; if ([self segDone:g]) continue;
            int64_t left = [g[@"e"] longLongValue] - ([g[@"s"] longLongValue] + [g[@"g"] longLongValue]) + 1;
            if (left > bestLeft) { bestLeft = left; best = k; }
        }
        if (best == NSNotFound) return;
        NSMutableDictionary *g = x.segs[best];
        if (!x.tasks[@(best)]) { [self startSeg:x index:best]; continue; }   // an idle slice: just restart it
        if (bestLeft < 2 * kMinSlice) return;                              // too small to be worth splitting
        int64_t cut = [g[@"s"] longLongValue] + [g[@"g"] longLongValue] + bestLeft / 2, end = [g[@"e"] longLongValue];
        g[@"e"] = @(cut - 1);
        [x.segs addObject:[@{@"s": @(cut), @"e": @(end), @"g": @0, @"tries": @0} mutableCopy]];
        [self startSeg:x index:x.segs.count - 1];
    }
}

- (void)retry:(VDownload *)x index:(NSUInteger)i why:(NSString *)why {
    NSMutableDictionary *g = x.segs[i];
    NSInteger tries = [g[@"tries"] integerValue] + 1; g[@"tries"] = @(tries);
    if (tries > 5) { [self fail:x why:why ?: @"The connection kept failing"]; return; }
    if (!x.resumable && x.received > 0) { [self restartWhole:x]; return; }
    __weak FAccel *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(tries * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FAccel *me = ws; if (!me) return;
        [me->_q addOperationWithBlock:^{ if ([x.state isEqual:@"running"] && !x.tasks[@(i)] && ![me segDone:g]) [me startSeg:x index:i]; }];
    });
}

- (void)restartWhole:(VDownload *)x {
    for (NSURLSessionDataTask *t in x.tasks.allValues) [t cancel];
    [x.tasks removeAllObjects];
    x.resumable = NO; x.received = 0;
    [x.fh truncateFileAtOffset:0];
    x.segs = [NSMutableArray arrayWithObject:[@{@"s": @0, @"e": @-1, @"g": @0, @"tries": @1} mutableCopy]];
    [self startSeg:x index:0];
}

#pragma mark Ending

- (void)finish:(VDownload *)x {
    for (NSURLSessionDataTask *t in x.tasks.allValues) [t cancel];
    [x.tasks removeAllObjects]; x.conns = 0;
    @try { if (x.total > 0) [x.fh truncateFileAtOffset:(unsigned long long)x.total]; [x.fh synchronizeFile]; [x.fh closeFile]; } @catch (NSException *e) {}
    x.fh = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *dest = x.path;
        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) dest = UniquePath(dest.stringByDeletingLastPathComponent, dest.lastPathComponent);
        NSError *e = nil;
        if (![NSFileManager.defaultManager moveItemAtPath:x.partPath toPath:dest error:&e]) { x.state = @"failed"; x.error = e.localizedDescription; [VDownloads.shared save]; [VDownloads.shared changed]; return; }
        x.path = dest; x.name = dest.lastPathComponent;
        MarkQuarantined(dest, x.url);
        NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:dest error:nil];
        x.total = x.received = (int64_t)at.fileSize;
        x.state = @"done"; x.ended = NSDate.date.timeIntervalSince1970; x.speed = 0;
        if (x.ended > x.started) x.peak = MAX(x.peak, x.total / (x.ended - x.started));
        [VDownloads.shared save]; [VDownloads.shared changed];
        [gWin showToast:[NSString stringWithFormat:@"Downloaded %@", x.name]];
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.apple.DownloadFileFinished" object:dest];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 61 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ for (VWindow *w in gWindows) [w.toolbar layoutBar]; });
        [self->_q addOperationWithBlock:^{ [self schedule]; }];
    });
}

- (void)fail:(VDownload *)x why:(NSString *)why {
    for (NSURLSessionDataTask *t in x.tasks.allValues) [t cancel];
    [x.tasks removeAllObjects]; x.conns = 0;
    x.state = @"failed"; x.error = why; x.ended = NSDate.date.timeIntervalSince1970; x.speed = 0;
    @try { [x.fh synchronizeFile]; [x.fh closeFile]; } @catch (NSException *e) {}
    x.fh = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [VDownloads.shared save]; [VDownloads.shared changed]; [gWin showToast:[NSString stringWithFormat:@"Download failed: %@", x.name]]; });
    [self schedule];
}

// Flint couldn't fetch it itself (the site refuses a second request): WebKit downloads it the usual way.
- (void)handBackToWebKit:(VDownload *)x why:(NSString *)why {
    for (NSURLSessionDataTask *t in x.tasks.allValues) [t cancel];
    [x.tasks removeAllObjects];
    @try { [x.fh closeFile]; } @catch (NSException *e) {}
    x.fh = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSFileManager.defaultManager removeItemAtPath:x.partPath error:nil];
        [VDownloads.shared.items removeObject:x];
        WKWebView *v = x.view ?: gWin.current.web.web;
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:x.url]];
        if (x.referer.length) [r setValue:x.referer forHTTPHeaderField:@"Referer"];
        DLog(@"downloads: %@ handed to WebKit (%@)", HostOf([NSURL URLWithString:x.url]), why);
        if (v) [v startDownloadUsingRequest:r completionHandler:^(WKDownload *d) { d.delegate = (id<WKDownloadDelegate>)v.navigationDelegate; }];
        [VDownloads.shared changed];
    });
    [self schedule];
}

#pragma mark Controls

- (void)pause:(VDownload *)x {
    [_q addOperationWithBlock:^{
        if (![@[@"running", @"queued"] containsObject:x.state ?: @""]) return;
        x.state = @"paused"; x.speed = 0;
        for (NSURLSessionDataTask *t in x.tasks.allValues) [t cancel];
        [x.tasks removeAllObjects]; x.conns = 0;
        @try { [x.fh synchronizeFile]; [x.fh closeFile]; } @catch (NSException *e) {}
        x.fh = nil;
        if (!x.resumable) { x.received = 0; x.segs = [NSMutableArray arrayWithObject:[@{@"s": @0, @"e": @-1, @"g": @0, @"tries": @0} mutableCopy]]; [NSFileManager.defaultManager removeItemAtPath:x.partPath error:nil]; }
        [self changedMain]; [self schedule];
    }];
}
- (void)resume:(VDownload *)x {
    if (![@[@"paused", @"failed"] containsObject:x.state ?: @""]) return;
    if ([x.kind isEqual:@"webkit"]) {   // an old WebKit download: fetch it again with the accelerator
        [VDownloads.shared.items removeObject:x]; [VDownloads.shared changed];
        [self downloadURL:[NSURL URLWithString:x.url] name:x.name referer:nil view:gWin.current.web.web private:NO];
        return;
    }
    x.state = @"queued"; x.error = nil;
    for (NSMutableDictionary *g in x.segs) g[@"tries"] = @0;
    if (![NSFileManager.defaultManager fileExistsAtPath:x.partPath]) { x.received = 0; x.segs = [NSMutableArray arrayWithObject:[@{@"s": @0, @"e": @-1, @"g": @0, @"tries": @0} mutableCopy]]; }
    [VDownloads.shared changed];
    [self withCookiesFor:x then:^{ [self->_q addOperationWithBlock:^{ [self schedule]; }]; }];
}
- (void)cancel:(VDownload *)x {
    [_q addOperationWithBlock:^{
        for (NSURLSessionDataTask *t in x.tasks.allValues) [t cancel];
        [x.tasks removeAllObjects]; x.conns = 0;
        @try { [x.fh closeFile]; } @catch (NSException *e) {}
        x.fh = nil;
        if ([x.kind isEqual:@"accel"] && x.partPath) [NSFileManager.defaultManager removeItemAtPath:x.partPath error:nil];
        x.state = @"cancelled"; x.speed = 0; x.ended = NSDate.date.timeIntervalSince1970;
        [self changedMain]; [self schedule];
    }];
    if ([x.kind isEqual:@"webkit"] && x.wk) { x.state = @"cancelled"; [x.wk cancel:nil]; }
}
- (void)pauseAll { for (VDownload *x in VDownloads.shared.items.copy) if ([x.kind isEqual:@"accel"]) [self pause:x]; }
- (void)resumeAll { for (VDownload *x in VDownloads.shared.items.copy) if ([x.kind isEqual:@"accel"] && [x.state isEqual:@"paused"]) [self resume:x]; }
- (int64_t)currentSpeed { return _speed; }

#pragma mark Pace

- (void)hold:(BOOL)on {
    _held = on;
    for (VDownload *x in VDownloads.shared.items.copy) for (NSURLSessionDataTask *t in x.tasks.allValues) { if (on) [t suspend]; else [t resume]; }
}
// every half second: speeds, the speed limit's next allowance, and the line
- (void)tick {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970; int64_t all = 0; BOOL any = NO;
    for (VDownload *x in VDownloads.shared.items.copy) {
        if (![x.kind isEqual:@"accel"] || ![x.state isEqual:@"running"]) continue;
        any = YES;
        double dt = MAX(0.2, now - x.lastTick), sp = (x.received - x.lastBytes) / dt;
        x.speed = x.speed > 0 ? x.speed * 0.55 + sp * 0.45 : sp;
        x.peak = MAX(x.peak, x.speed);
        x.lastTick = now; x.lastBytes = x.received;
        all += (int64_t)x.speed;
    }
    _speed = all;
    _windowBytes = 0;
    if (_held) [self hold:NO];
    if (any) { [self changedMain]; if ((int)(now * 2) % 6 == 0) dispatch_async(dispatch_get_main_queue(), ^{ [VDownloads.shared save]; }); }
}
- (void)changedMain { dispatch_async(dispatch_get_main_queue(), ^{ [VDownloads.shared changed]; }); }
@end
#pragma mark - WebKit: shared configuration, ad blocking, the page view


static WKUserContentController *gUCC;
static WKUserContentController *gPrivUCC;   // private windows: Flint's helpers only, no extensions
static void FlintApplyRules(void);
static WKProcessPool *gPool;
static BOOL gBlockOn = YES;
static NSArray<WKContentRuleList *> *gRules;
static NSUInteger gRuleCount;
static BOOL gAskNextDownload;   // "Save Image As…": ask where, once
// Hosts whose broken certificate the person chose to accept; kept until Flint quits, like Chrome.
static NSMutableSet<NSString *> *gCertOK;


// Safari's identity, so sites treat Flint like Safari rather than an unknown embedded browser.
static NSString *const kAppUA = @"Version/18.6 Safari/605.1.15";

static NSString *HoverScript(void) {
    return @"(()=>{let last=null;const send=h=>{if(h!==last){last=h;try{webkit.messageHandlers.flintHover.postMessage(h||'')}catch(e){}}};"
            "document.addEventListener('mouseover',e=>{const a=e.target.closest&&e.target.closest('a[href]');send(a?a.href:null)},true);"
            "document.addEventListener('mouseout',e=>{if(!e.relatedTarget)send(null)},true);})();";
}

@interface FWebView : WKWebView {
    NSDictionary *_ctx;
    NSTimeInterval _ctxAt;
}
@property (weak) VPage *page;
- (void)setContext:(NSDictionary *)c;
@end

static NSString *ContextScript(void) {
    return @"(()=>{document.addEventListener('contextmenu',e=>{try{const t=e.target,el=t&&t.nodeType===1?t:t&&t.parentElement;"
            "const a=el&&el.closest('a[href]');const img=el&&(el.closest('img')||el.closest('picture')&&el.closest('picture').querySelector('img'));"
            "const vid=el&&el.closest('video');const sel=String(getSelection()||'').trim();"
            "const ed=!!(el&&(el.isContentEditable||/^(INPUT|TEXTAREA)$/.test(el.tagName)));window.__flintCtxEl=el;"
            "webkit.messageHandlers.flintContext.postMessage({link:a?a.href:'',image:img?(img.currentSrc||img.src||''):'',video:vid?(vid.currentSrc||vid.src||'x'):'',selection:sel.slice(0,2000),editable:ed})}catch(x){}},true)})();";
}

// Chrome Web Store pages get an "Add to Flint" button (the store itself only offers Chrome).
static NSString *WebStoreScript(void) {
    return @"(()=>{if(location.hostname!=='chromewebstore.google.com')return;let btn=null;"
            "const sync=()=>{const m=location.pathname.match(/\\/detail\\/[^/]*\\/([a-p]{32})/)||location.pathname.match(/\\/detail\\/([a-p]{32})/);"
            "if(!m){if(btn){btn.remove();btn=null}return}if(btn&&btn.dataset.id===m[1])return;if(btn)btn.remove();"
            "btn=document.createElement('button');btn.dataset.id=m[1];btn.textContent='Add to Flint';"
            "btn.style.cssText='position:fixed;top:84px;right:28px;z-index:2147483647;padding:10px 20px;border-radius:999px;border:0;font:600 14px -apple-system,system-ui;color:#111;background:#f2f2f4;box-shadow:0 6px 20px rgba(0,0,0,.3);cursor:pointer';"
            "btn.onclick=()=>{const h=document.querySelector('h1');webkit.messageHandlers.flintInstall.postMessage({id:m[1],name:h?h.textContent.trim():''})};"
            "document.documentElement.appendChild(btn)};"
            // the store's "Switch to Chrome" banner and pop-over: hidden (Flint installs extensions itself)
            "const hideNag=()=>{const w=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_TEXT);let n;"
            "while((n=w.nextNode())){if(!/Switch to Chrome|Install Chrome|Download Chrome/i.test(n.nodeValue))continue;let el=n.parentElement;if(!el||el.dataset.flintHidden)continue;"
            "const dlg=el.closest('[role=dialog]');if(dlg){dlg.style.setProperty('display','none','important');dlg.dataset.flintHidden=1;continue}"
            "while(el.parentElement&&el.parentElement!==document.body&&el.parentElement.textContent.trim().length<140)el=el.parentElement;"
            "el.style.setProperty('display','none','important');el.dataset.flintHidden=1}};"
            "setInterval(()=>{sync();hideNag()},800);sync();hideNag()})();";
}

@interface VInstallRelay : NSObject <WKScriptMessageHandler>
@end
@implementation VInstallRelay
- (void)userContentController:(WKUserContentController *)u didReceiveScriptMessage:(WKScriptMessage *)m {
    if (![m.frameInfo.securityOrigin.host isEqualToString:@"chromewebstore.google.com"] || ![m.body isKindOfClass:NSDictionary.class]) return;
    NSString *ident = m.body[@"id"], *name = [m.body[@"name"] length] ? m.body[@"name"] : @"this extension";
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Add “%@” to Flint?", name];
    a.informativeText = @"It runs on Flint's own extension layer. Most extensions work; some Chrome-only features may not.";
    [a addButtonWithTitle:@"Add Extension"]; [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:gWin.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        [gWin showToast:[NSString stringWithFormat:@"Installing %@…", name]];
        [FExtHost.shared installFromWebStore:ident done:^(NSString *installed, NSString *err) {
            NSAlert *b = [NSAlert new];
            if (err) { b.messageText = @"Couldn't add the extension"; b.informativeText = err; [b beginSheetModalForWindow:gWin.window completionHandler:nil]; return; }
            b.messageText = [NSString stringWithFormat:@"%@ is installed", installed ?: name];
            b.informativeText = @"Relaunch Flint to start it. Your tabs come back.";
            [b addButtonWithTitle:@"Relaunch Now"]; [b addButtonWithTitle:@"Later"];
            [b beginSheetModalForWindow:gWin.window completionHandler:^(NSModalResponse rr) { if (rr == NSAlertFirstButtonReturn) FlintRelaunch(); }];
        }];
    }];
}
@end

@interface VContextRelay : NSObject <WKScriptMessageHandler>
@end
@implementation VContextRelay
- (void)userContentController:(WKUserContentController *)u didReceiveScriptMessage:(WKScriptMessage *)m {
    if ([m.webView isKindOfClass:FWebView.class] && [m.body isKindOfClass:NSDictionary.class]) [(FWebView *)m.webView setContext:m.body];
}
@end

@interface VHoverRelay : NSObject <WKScriptMessageHandler>
@end
@implementation VHoverRelay
- (void)userContentController:(WKUserContentController *)u didReceiveScriptMessage:(WKScriptMessage *)m {
    if (!m.frameInfo.isMainFrame) return;
    for (VTab *t in AllTabs(YES)) if (t.web.web == m.webView) {
        NSString *s = [m.body isKindOfClass:NSString.class] ? m.body : nil;
        if (t == t.owner.current) [t.owner showLink:s.length ? s : nil];
    }
}
@end

// Codec forcing (like h264ify): sites ask the browser which video formats it can play before choosing a stream.
// Saying "no" to AV1 (and VP9) makes YouTube and others send H.264, which the Mac's video hardware decodes;
// the others often fall back to the processor. Optionally 60 fps streams are refused too.
static BOOL MacIsAppleSilicon(void) { int v = 0; size_t n = sizeof v; return sysctlbyname("hw.optional.arm64", &v, &n, NULL, 0) == 0 && v == 1; }
static NSString *CodecConfigJS(void) {
    return [NSString stringWithFormat:@"try{Object.defineProperty(window,'__flintCodec',{value:{mode:%ld,fps30:%@},configurable:true,enumerable:false})}catch(e){}",
            (long)[Defaults() integerForKey:kCodec], [Defaults() boolForKey:kCodec30] ? @"true" : @"false"];
}
static NSString *CodecScript(void) {
    return @"(()=>{const cfg=()=>window.__flintCodec||{mode:0,fps30:false};"
    "const refuse=t=>{const c=cfg();if(!c.mode&&!c.fps30)return false;t=String(t||'').toLowerCase();"
      "if(c.mode>=1&&/av01|av1/.test(t))return true;"
      "if(c.mode>=2&&(/vp0?[89]|vp09/.test(t)||/^video\\/webm/.test(t)))return true;"
      "if(c.fps30){const m=/framerate=(\\d+)/.exec(t);if(m&&+m[1]>30)return true}return false};"
    "for(const MS of [window.MediaSource,window.ManagedMediaSource,window.WebKitMediaSource]){if(MS&&MS.isTypeSupported){const o=MS.isTypeSupported.bind(MS);MS.isTypeSupported=t=>refuse(t)?false:o(t)}}"
    "const cp=HTMLMediaElement.prototype.canPlayType;HTMLMediaElement.prototype.canPlayType=function(t){return refuse(t)?'':cp.call(this,t)};"
    "const mc=navigator.mediaCapabilities;if(mc&&mc.decodingInfo){const d=mc.decodingInfo.bind(mc);mc.decodingInfo=c=>{const v=c&&c.video;"
      "if(v&&(refuse(v.contentType)||(cfg().fps30&&+v.framerate>30)))return Promise.resolve({supported:false,smooth:false,powerEfficient:false});return d(c)}}"
    "})();";
}
static void FlintCodecInstall(WKUserContentController *ucc) {
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:CodecConfigJS() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:WKContentWorld.pageWorld]];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:CodecScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:WKContentWorld.pageWorld]];
}
// A settings change adds a newer config (it runs later, so it wins); pages pick it up when they next load.
static void FlintCodecChanged(void) {
    for (WKUserContentController *u in @[gUCC ?: (id)NSNull.null, gPrivUCC ?: (id)NSNull.null]) {
        if (![u isKindOfClass:WKUserContentController.class]) continue;
        [u addUserScript:[[WKUserScript alloc] initWithSource:CodecConfigJS() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:WKContentWorld.pageWorld]];
    }
}

// One engine process for every tab (memory saver). Read once at launch: the process pool can't change later.
static WKProcessPool *MakeProcessPool(void) {
    Class PC = NSClassFromString(@"_WKProcessPoolConfiguration");
    SEL init = NSSelectorFromString(@"_initWithConfiguration:");
    if (![Defaults() boolForKey:kSingleProcess] || !PC || ![WKProcessPool instancesRespondToSelector:init]) return [WKProcessPool new];
    id pc = [PC new];
    @try { [pc setValue:@YES forKey:@"usesSingleWebProcess"]; } @catch (NSException *e) { return [WKProcessPool new]; }
    return ((id (*)(id, SEL, id))objc_msgSend)([WKProcessPool alloc], init, pc);
}

// Background tabs: WebKit can slow a hidden page's timers further the longer it stays hidden (Safari does;
// apps built on WebKit don't by default). "Save power on battery" turns that on only when unplugged.
static BOOL OnBattery(void) {
    static CFTypeRef (*copyInfo)(void); static CFStringRef (*providing)(CFTypeRef); static BOOL tried;
    if (!tried) { tried = YES; void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (h) { copyInfo = (CFTypeRef (*)(void))dlsym(h, "IOPSCopyPowerSourcesInfo"); providing = (CFStringRef (*)(CFTypeRef))dlsym(h, "IOPSGetProvidingPowerSourceType"); } }
    if (!copyInfo || !providing) return NO;
    CFTypeRef info = copyInfo(); if (!info) return NO;
    CFStringRef t = providing(info);
    BOOL b = t && CFStringCompare(t, CFSTR("Battery Power"), 0) == kCFCompareEqualTo;
    CFRelease(info);
    return b;
}
static BOOL ThrottleHard(void) { NSInteger m = [Defaults() integerForKey:kBgThrottle]; return m == 2 || (m == 1 && OnBattery()); }
static void ApplyThrottle(WKWebView *w, BOOL hard) {
    WKPreferences *p = w.configuration.preferences;
    SEL a = NSSelectorFromString(@"_setHiddenPageDOMTimerThrottlingAutoIncreases:"), en = NSSelectorFromString(@"_setHiddenPageDOMTimerThrottlingEnabled:"), sup = NSSelectorFromString(@"_setPageVisibilityBasedProcessSuppressionEnabled:");
    if ([p respondsToSelector:en]) ((void (*)(id, SEL, BOOL))objc_msgSend)(p, en, YES);
    if ([p respondsToSelector:sup]) ((void (*)(id, SEL, BOOL))objc_msgSend)(p, sup, YES);
    if ([p respondsToSelector:a]) ((void (*)(id, SEL, BOOL))objc_msgSend)(p, a, hard);
}

static WKWebViewConfiguration *FlintConfig(void) {
    if (!gUCC) {
        gPool = MakeProcessPool();
        // extension pages (chrome-extension://) count as secure, like in Chrome, so crypto.subtle etc. work
        SEL secure = NSSelectorFromString(@"_registerURLSchemeAsSecure:");
        if ([gPool respondsToSelector:secure]) ((void (*)(id, SEL, id))objc_msgSend)(gPool, secure, @"chrome-extension");
        SEL csp = NSSelectorFromString(@"_registerURLSchemeAsBypassingContentSecurityPolicy:");
        if ([gPool respondsToSelector:csp]) ((void (*)(id, SEL, id))objc_msgSend)(gPool, csp, @"chrome-extension");
        gUCC = [WKUserContentController new];
        // Flint's own page helpers run in their own JavaScript world: pages can't see or spoof them
        WKContentWorld *mine = [WKContentWorld worldWithName:@"flint"];
        [gUCC addUserScript:[[WKUserScript alloc] initWithSource:HoverScript() injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES inContentWorld:mine]];
        [gUCC addScriptMessageHandler:[VHoverRelay new] contentWorld:mine name:@"flintHover"];
        [gUCC addUserScript:[[WKUserScript alloc] initWithSource:ContextScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:mine]];
        [gUCC addScriptMessageHandler:[VContextRelay new] contentWorld:mine name:@"flintContext"];
        [gUCC addUserScript:[[WKUserScript alloc] initWithSource:WebStoreScript() injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES inContentWorld:mine]];
        [gUCC addScriptMessageHandler:[VInstallRelay new] contentWorld:mine name:@"flintInstall"];
        FlintCosmeticInstall(gUCC);
        FlintCodecInstall(gUCC);
        // Global Privacy Control: tells sites you don't consent to your data being sold or shared
        if ([Defaults() boolForKey:kGPC])
            [gUCC addUserScript:[[WKUserScript alloc] initWithSource:@"try{Object.defineProperty(Navigator.prototype,'globalPrivacyControl',{get:()=>true,configurable:true})}catch(e){}"
                                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:WKContentWorld.pageWorld]];
    }
    WKWebViewConfiguration *c = [WKWebViewConfiguration new];
    c.processPool = gPool;
    c.userContentController = gUCC;
    c.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    c.applicationNameForUserAgent = kAppUA;
    c.allowsAirPlayForMediaPlayback = YES;
    c.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    c.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    if (@available(macOS 12.3, *)) c.preferences.elementFullscreenEnabled = YES;
    c.preferences.fraudulentWebsiteWarningEnabled = NO;   // no lookups sent to Google Safe Browsing
    @try { [c.preferences setValue:@YES forKey:@"developerExtrasEnabled"]; } @catch (NSException *e) {}
    // Picture in Picture: off by default for apps built on WebKit (Safari turns it on); without it every video
    // says "does not support the Picture-in-Picture mode"
    SEL pip = NSSelectorFromString(@"_setAllowsPictureInPictureMediaPlayback:");
    if ([c.preferences respondsToSelector:pip]) ((void (*)(id, SEL, BOOL))objc_msgSend)(c.preferences, pip, YES);
    else { static BOOL said; if (!said) { said = YES; DLog(@"picture in picture: this WebKit has no switch for it"); } }    c.defaultWebpagePreferences.allowsContentJavaScript = [Defaults() boolForKey:kScripts];
    if ([Defaults() integerForKey:kMinFont] > 0) c.preferences.minimumFontSize = [Defaults() integerForKey:kMinFont];
    if ([Defaults() integerForKey:kUserAgent] == 1) c.applicationNameForUserAgent = @"Chrome/140.0.0.0 Safari/537.36";
    if (@available(macOS 12.0, *)) c.upgradeKnownHostsToHTTPS = YES;
    [FExtHost.shared install:gUCC config:c];
    FlintInternalInstall(c, gUCC);
    return c;
}

// Private windows: same engine settings, but their own in-memory website data and no extensions.
static WKWebViewConfiguration *PrivateConfig(WKWebsiteDataStore *store) {
    WKWebViewConfiguration *c = FlintConfig();
    if (!gPrivUCC) {
        gPrivUCC = [WKUserContentController new];
        WKContentWorld *mine = [WKContentWorld worldWithName:@"flint"];
        [gPrivUCC addUserScript:[[WKUserScript alloc] initWithSource:HoverScript() injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES inContentWorld:mine]];
        [gPrivUCC addScriptMessageHandler:[VHoverRelay new] contentWorld:mine name:@"flintHover"];
        [gPrivUCC addUserScript:[[WKUserScript alloc] initWithSource:ContextScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:mine]];
        [gPrivUCC addScriptMessageHandler:[VContextRelay new] contentWorld:mine name:@"flintContext"];
        if ([Defaults() boolForKey:kGPC])
            [gPrivUCC addUserScript:[[WKUserScript alloc] initWithSource:@"try{Object.defineProperty(Navigator.prototype,'globalPrivacyControl',{get:()=>true,configurable:true})}catch(e){}"
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:WKContentWorld.pageWorld]];
        FlintCosmeticInstall(gPrivUCC);
        FlintCodecInstall(gPrivUCC);
        FlintApplyRules();
    }
    c.userContentController = gPrivUCC;
    FlintInternalInstall(c, gPrivUCC);
    c.websiteDataStore = store ?: WKWebsiteDataStore.nonPersistentDataStore;
    return c;
}

// A profile's pages: everything as usual (extensions, blocking, Flint's helpers), with that profile's own website data.
static WKWebViewConfiguration *ProfileConfig(NSString *pid) {
    WKWebViewConfiguration *c = FlintConfig();
    if (pid.length) c.websiteDataStore = ProfileStore(pid);
    return c;
}

#pragma mark Blocking: filter-list hosts compiled into WebKit content rules (blocked inside WebKit, no per-request cost)

static NSString *RuleHostRegex(NSString *h) {
    NSMutableString *r = [NSMutableString string];
    for (NSUInteger i = 0; i < h.length; i++) {
        unichar c = [h characterAtIndex:i];
        if (c == '.') [r appendString:@"\\."];
        else if (isalnum(c) || c == '-' || c == '_') [r appendFormat:@"%C", c];
        else return nil;
    }
    return r;
}

static void FlintApplyRules(void) {
    for (WKUserContentController *u in @[gUCC ?: (id)NSNull.null, gPrivUCC ?: (id)NSNull.null]) {
        if (![u isKindOfClass:WKUserContentController.class]) continue;
        [u removeAllContentRuleLists];
        if (gBlockOn) for (WKContentRuleList *l in gRules) [u addContentRuleList:l];
        // extensions' own blocking rules (declarativeNetRequest): normal windows only, like the extensions themselves
        if (u == gUCC) for (NSArray *lists in gExtRuleLists.allValues) for (WKContentRuleList *l in lists) [u addContentRuleList:l];
    }
}

static void FlintSetBlocking(BOOL on) { gBlockOn = on; FlintApplyRules(); }

static NSString *RulesFingerprint(NSString *dir, NSArray *allow) {
    NSMutableString *fp = [NSMutableString stringWithString:@"v2|"];
    for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        [fp appendFormat:@"%@:%llu:%.0f|", f, a.fileSize, a.fileModificationDate.timeIntervalSince1970];
    }
    [fp appendString:[allow componentsJoinedByString:@","]];
    return fp;
}

static void (^gRulesWaiter)(void);
static void FlintReloadBlocklistsThen(void (^then)(void)) {
    NSString *dir = SupportFile(@"lists");
    NSArray *allow = [Defaults() arrayForKey:kAllowlist] ?: @[];
    NSString *fp = RulesFingerprint(dir, allow);
    gRulesWaiter = then;
    void (^finish)(NSArray *, NSUInteger) = ^(NSArray *lists, NSUInteger count) {
        gRules = lists; gRuleCount = count;
        FlintApplyRules();
        void (^w)(void) = gRulesWaiter; gRulesWaiter = nil; if (w) w();
    };
    // Same lists as last time: WebKit already has them compiled on disk.
    NSUInteger cached = (NSUInteger)[Defaults() integerForKey:@"ruleListCount"];
    if (cached && [[Defaults() stringForKey:@"ruleFingerprint"] isEqualToString:fp]) {
        NSMutableArray *found = [NSMutableArray array];
        __block NSUInteger pending = cached; __block BOOL missing = NO;
        for (NSUInteger k = 0; k < cached; k++) {
            [WKContentRuleListStore.defaultStore lookUpContentRuleListForIdentifier:[NSString stringWithFormat:@"flint-block-%lu", (unsigned long)k] completionHandler:^(WKContentRuleList *l, NSError *e) {
                if (l) [found addObject:l]; else missing = YES;
                if (--pending) return;
                if (!missing) { finish(found, (NSUInteger)[Defaults() integerForKey:@"ruleHostCount"]); DLog(@"blocker: %lu cached lists", (unsigned long)found.count); }
                else { [Defaults() removeObjectForKey:@"ruleFingerprint"]; FlintReloadBlocklistsThen(gRulesWaiter); }
            }];
        }
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableSet<NSString *> *hosts = [NSMutableSet set], *exc = [NSMutableSet set];
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
            if (![f.pathExtension isEqualToString:@"txt"]) continue;
            NSString *text = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
            for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                NSString *l = Trim(raw); BOOL x = NO;
                if ([l hasPrefix:@"@@||"]) { x = YES; l = [l substringFromIndex:4]; } else if ([l hasPrefix:@"||"]) l = [l substringFromIndex:2]; else continue;
                NSString *opts = @""; NSRange d = [l rangeOfString:@"$"];
                if (d.location != NSNotFound) { opts = [l substringFromIndex:d.location + 1]; l = [l substringToIndex:d.location]; }
                if (opts.length && ![opts isEqualToString:@"third-party"] && ![opts isEqualToString:@"3p"] && ![opts isEqualToString:@"important"] && !(x && [opts containsString:@"document"])) continue;
                while ([l hasSuffix:@"^"] || [l hasSuffix:@"|"]) l = [l substringToIndex:l.length - 1];
                if (!l.length || [l rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/*^"]].location != NSNotFound || ![l containsString:@"."]) continue;
                [(x ? exc : hosts) addObject:l.lowercaseString];
            }
        }
        [hosts minusSet:exc];
        // WebKit allows 150k rules per list; 40k per list keeps each compile quick. Every list ends with the
        // sites you've turned blocking off for (ignore-previous-rules only reaches rules in its own list).
        NSArray *all = [hosts.allObjects sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *chunks = [NSMutableArray array];
        for (NSUInteger i = 0; i < MAX(all.count, 1); i += 40000) {
            NSMutableArray *rules = [NSMutableArray array];
            for (NSString *h in all.count ? [all subarrayWithRange:NSMakeRange(i, MIN(40000, all.count - i))] : @[]) {
                NSString *rx = RuleHostRegex(h); if (!rx) continue;
                [rules addObject:@{@"trigger": @{@"url-filter": [NSString stringWithFormat:@"^[a-z]+://([^/:]+\\.)?%@[:/]", rx], @"load-type": @[@"third-party"]},
                                   @"action": @{@"type": @"block"}}];
            }
            if (!rules.count) [rules addObject:@{@"trigger": @{@"url-filter": @"^flint-never:"}, @"action": @{@"type": @"block"}}];
            for (NSString *site in allow) if ([site isKindOfClass:NSString.class] && RuleHostRegex(site))
                [rules addObject:@{@"trigger": @{@"url-filter": @".*", @"if-top-url": @[[NSString stringWithFormat:@"^[a-z]+://([^/:]+\\.)?%@[:/]", RuleHostRegex(site)]]},
                                   @"action": @{@"type": @"ignore-previous-rules"}}];
            [chunks addObject:[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:rules options:0 error:nil] encoding:NSUTF8StringEncoding]];
        }
        NSUInteger count = all.count;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *lists = [NSMutableArray array];
            __block NSUInteger pending = chunks.count;
            NSDate *t0 = NSDate.date;
            for (NSUInteger k = 0; k < chunks.count; k++) {
                NSString *ident = [NSString stringWithFormat:@"flint-block-%lu", (unsigned long)k];
                [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:ident encodedContentRuleList:chunks[k] completionHandler:^(WKContentRuleList *list, NSError *err) {
                    if (list) [lists addObject:list]; else DLog(@"rule list %@ failed: %@", ident, err);
                    if (--pending) return;
                    if (lists.count == chunks.count) {
                        [Defaults() setObject:fp forKey:@"ruleFingerprint"];
                        [Defaults() setInteger:(NSInteger)lists.count forKey:@"ruleListCount"];
                        [Defaults() setInteger:(NSInteger)count forKey:@"ruleHostCount"];
                    }
                    finish(lists, count);
                    DLog(@"blocker: %lu hosts in %lu lists, compiled in %.1fs", (unsigned long)count, (unsigned long)lists.count, -t0.timeIntervalSinceNow);
                }];
            }
        });
    });
}
static void FlintReloadBlocklists(void) { FlintReloadBlocklistsThen(nil); }

#pragma mark - Page view


@interface VPage () <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@end

@implementation FWebView
// What's under the pointer, reported by Flint's own script (its own world, so pages can't fake it)
// a moment before WebKit asks for the menu.
- (void)setContext:(NSDictionary *)c { _ctx = c; _ctxAt = NSDate.timeIntervalSinceReferenceDate; }

// Safari's context menu (Look Up, Translate, Share, spelling…) with Chrome's link/image/page items added.
- (void)willOpenMenu:(NSMenu *)menu withEvent:(NSEvent *)event {
    [super willOpenMenu:menu withEvent:event];
    NSDictionary *c = NSDate.timeIntervalSinceReferenceDate - _ctxAt < 2 ? _ctx : @{};
    NSString *(^str)(NSString *) = ^NSString *(NSString *k) { id v = c[k]; return [v isKindOfClass:NSString.class] && [v length] ? v : nil; };
    NSString *link = str(@"link"), *image = str(@"image"), *video = str(@"video"), *sel = str(@"selection");
    BOOL editable = [c[@"editable"] boolValue];
    NSMenuItem *(^make)(NSString *, SEL, id) = ^NSMenuItem *(NSString *t, SEL a, id obj) {
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:@""]; i.target = (self.page.tab.owner ?: gWin); i.representedObject = obj; return i;
    };
    void (^insertAfter)(NSMenuItem *, NSArray *) = ^(NSMenuItem *after, NSArray *items) {
        NSInteger at = [menu indexOfItem:after] + 1;
        for (NSMenuItem *i in items) [menu insertItem:i atIndex:at++];
    };
    BOOL sawLink = NO, sawImage = NO;
    for (NSMenuItem *i in menu.itemArray.copy) {
        NSString *ident = i.identifier ?: @"";
        if ([ident isEqualToString:@"WKMenuItemIdentifierOpenLinkInNewWindow"]) {
            sawLink = YES; i.title = @"Open Link in New Tab";
            if (link) insertAfter(i, @[make(@"Peek Link", @selector(peekLink:), link), make(@"Open Link in Split View", @selector(splitLink:), link), make(@"Open Link in Background Tab", @selector(openLinkInBackground:), link),
                                       make(@"Open Link in Default Browser", @selector(openInDefaultBrowser:), link)]);
        } else if ([ident isEqualToString:@"WKMenuItemIdentifierCopyLink"]) {
            NSURL *u = link ? [NSURL URLWithString:link] : nil; NSURL *clean = u ? StripTracking(u) : nil;
            NSMutableArray *more = [NSMutableArray array];
            if (clean) [more addObject:make(@"Copy Clean Link", @selector(copyText:), clean.absoluteString)];
            if (link) [more addObject:make(@"Bookmark Link", @selector(bookmarkURL:), link)];
            insertAfter(i, more);
        } else if ([ident isEqualToString:@"WKMenuItemIdentifierOpenImageInNewWindow"]) { sawImage = YES; i.title = @"Open Image in New Tab"; }
        else if ([ident isEqualToString:@"WKMenuItemIdentifierDownloadImage"]) {
            sawImage = YES; i.title = @"Save Image to Downloads";
            if (image) insertAfter(i, @[make(@"Save Image As…", @selector(saveImageAs:), image), make(@"Copy Image Address", @selector(copyText:), image)]);
        }
        else if ([ident isEqualToString:@"WKMenuItemIdentifierOpenMediaInNewWindow"]) i.title = @"Open Video in New Tab";
        else if ([ident isEqualToString:@"WKMenuItemIdentifierDownloadMedia"]) i.title = @"Save Video to Downloads";
        else if ([ident isEqualToString:@"WKMenuItemIdentifierDownloadLinkedFile"]) i.title = @"Download Linked File";
        else if ([ident isEqualToString:@"WKMenuItemIdentifierSearchWeb"] && sel) {
            // Safari's item always uses Google; this one uses your search engine
            NSString *shortSel = sel.length > 30 ? [[sel substringToIndex:29] stringByAppendingString:@"…"] : sel;
            i.title = [NSString stringWithFormat:@"Search %@ for “%@”", Engine()[0], [shortSel stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
            i.target = (self.page.tab.owner ?: gWin); i.action = @selector(searchFor:); i.representedObject = sel;
            NSURL *asURL = URLFromInput(sel);
            if (asURL && [sel rangeOfString:@" "].location == NSNotFound && [sel containsString:@"."] && ![asURL.host containsString:@"duckduckgo"] && ![asURL.absoluteString containsString:@"q="])
                insertAfter(i, @[make([NSString stringWithFormat:@"Go to %@", shortSel], @selector(openBookmarkInNewTab:), asURL.absoluteString)]);
        }
    }
    if (image && !sawImage) {
        [menu addItem:NSMenuItem.separatorItem];
        for (NSMenuItem *i in @[make(@"Open Image in New Tab", @selector(openBookmarkInNewTab:), image), make(@"Save Image As…", @selector(saveImageAs:), image), make(@"Copy Image Address", @selector(copyText:), image)]) [menu addItem:i];
    }
    if (link && !sawLink) {   // e.g. links WebKit didn't recognise
        [menu insertItem:NSMenuItem.separatorItem atIndex:0];
        NSArray *items = @[make(@"Open Link in New Tab", @selector(openBookmarkInNewTab:), link), make(@"Open Link in Background Tab", @selector(openLinkInBackground:), link), make(@"Copy Link", @selector(copyText:), link)];
        for (NSInteger k = (NSInteger)items.count - 1; k >= 0; k--) [menu insertItem:items[(NSUInteger)k] atIndex:0];
    }
    if (video) {
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:make(@"Picture in Picture", @selector(pictureInPicture:), nil)];
    }
    // the page itself
    if (!link && !image && !sel && !editable) {
        NSInteger at = menu.numberOfItems;
        for (NSInteger k = 0; k < menu.numberOfItems; k++) if ([[menu itemAtIndex:k].identifier isEqualToString:@"WKMenuItemIdentifierInspectElement"]) { at = k; break; }
        NSString *page = self.URL.absoluteString;
        NSURL *clean = self.URL ? StripTracking(self.URL) : nil;
        NSMutableArray *items = [NSMutableArray arrayWithObject:NSMenuItem.separatorItem];
        [items addObjectsFromArray:@[make(@"Bookmark This Page", @selector(toggleBookmark:), nil), make(@"Copy Page Link", @selector(copyText:), page)]];
        if (clean) [items addObject:make(@"Copy Clean Page Link", @selector(copyText:), clean.absoluteString)];
        [items addObjectsFromArray:@[NSMenuItem.separatorItem, make(@"Save Page As…", @selector(savePage:), nil), make(@"Print…", @selector(printPage:), nil),
                                     make(@"Find on Page…", @selector(showFind:), nil), make(@"View Page Source", @selector(viewSource:), nil),
                                     make(@"Open Page in Default Browser", @selector(openInDefaultBrowser:), page), NSMenuItem.separatorItem]];
        for (NSMenuItem *i in items) [menu insertItem:i atIndex:at++];
    }
    if ([self.URL.scheme hasPrefix:@"http"] && !editable) {
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:make(@"Block Element…", @selector(blockElement:), nil)];
    }
    // extensions' own items (chrome.contextMenus)
    if (!self.page.tab.owner.isPrivate) [FExtHost.shared addMenuItemsTo:menu context:c pageURL:self.URL.absoluteString view:self];
    // tidy: no leading, trailing or doubled separators
    for (NSInteger k = menu.numberOfItems - 1; k > 0; k--)
        if ([menu itemAtIndex:k].isSeparatorItem && [menu itemAtIndex:k - 1].isSeparatorItem) [menu removeItemAtIndex:k];
    while (menu.numberOfItems && menu.itemArray.firstObject.isSeparatorItem) [menu removeItemAtIndex:0];
    while (menu.numberOfItems && menu.itemArray.lastObject.isSeparatorItem) [menu removeItemAtIndex:menu.numberOfItems - 1];
}
@end

#define PW (self.tab.owner ?: gWin)
@implementation VPage {
    FWebView *_web;
    BOOL _observing, _audioKVO, _watchingLoad;
    NSString *_lastMethod;   // the request method of the latest navigation (only GET downloads can be accelerated)
    NSURL *_httpsUpgradeOf;
    NSString *_certErrorFor;   // host whose certificate warning is showing in this tab
    NSString *_pendingURL;
}
@synthesize web = _web;

static void *kKVO = &kKVO;

- (instancetype)initWithFrame:(NSRect)r { return [self initWithFrame:r web:nil]; }
- (instancetype)initWithFrame:(NSRect)r web:(WKWebView *)given {
    if (!(self = [super initWithFrame:r])) return nil;
    _back = [NSMutableArray array];
    _forward = [NSMutableArray array];
    _zoom = 1;
    self.wantsLayer = YES;
    self.layer.backgroundColor = vContentBg.CGColor;
    [self attach:(FWebView *)given];
    return self;
}

- (void)attach:(FWebView *)w {
    if (!w) w = [[FWebView alloc] initWithFrame:self.bounds configuration:self.tab.owner ? [self.tab.owner pageConfig] : FlintConfig()];
    _web = w;
    w.page = self;
    w.frame = self.bounds;
    w.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    w.navigationDelegate = self; w.UIDelegate = self;
    w.allowsBackForwardNavigationGestures = YES;
    w.allowsMagnification = YES;
    if (@available(macOS 12.0, *)) w.underPageBackgroundColor = vContentBg;
    @try { [w setValue:@NO forKey:@"drawsBackground"]; } @catch (NSException *e) {}
    if (@available(macOS 13.3, *)) w.inspectable = YES;
    if (fabs(_zoom - 1) > 0.01) w.pageZoom = _zoom;
    NSInteger ua = [Defaults() integerForKey:kUserAgent];
    if (ua == 1) w.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
    else if (ua == 2) w.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:143.0) Gecko/20100101 Firefox/143.0";
    for (NSString *k in @[@"title", @"URL", @"loading", @"estimatedProgress", @"canGoBack", @"canGoForward"])
        [w addObserver:self forKeyPath:k options:0 context:kKVO];
    @try { [w addObserver:self forKeyPath:@"_isPlayingAudio" options:0 context:kKVO]; _audioKVO = YES; } @catch (NSException *x) {}   // sound indicator in the sidebar
    _observing = YES;
    [self addSubview:w];
}

- (void)detach {
    if (!_web) return;
    if (_observing) for (NSString *k in @[@"title", @"URL", @"loading", @"estimatedProgress", @"canGoBack", @"canGoForward"]) [_web removeObserver:self forKeyPath:k context:kKVO];
    if (_audioKVO) { @try { [_web removeObserver:self forKeyPath:@"_isPlayingAudio" context:kKVO]; } @catch (NSException *x) {} _audioKVO = NO; }
    _observing = NO;
    [_web stopLoading];
    _web.navigationDelegate = nil; _web.UIDelegate = nil; _web.page = nil;
    [_web removeFromSuperview];
    _web = nil;
}

- (void)dealloc { [self detach]; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)close { [self detach]; [self removeFromSuperview]; }

- (void)focus { if (self.window && _web) [self.window makeFirstResponder:_web]; }

- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
    if (ctx != kKVO) { [super observeValueForKeyPath:k ofObject:o change:c context:ctx]; return; }
    if ([k isEqualToString:@"title"]) { if (_web.title.length) self.title = _web.title; }
    else if ([k isEqualToString:@"URL"]) { if (_web.URL) self.url = _web.URL.absoluteString; }
    else if ([k isEqualToString:@"loading"]) {
        BOOL finished = self.loading && !_web.loading;
        self.loading = _web.loading;
        if (self.loading) [self watchLoading];
        if (finished && [self.url hasPrefix:@"http"] && !self.tab.owner.isPrivate) [[VHistory forProfile:self.tab.owner.profile] visit:_web.URL title:self.title];
    }
    else if ([k isEqualToString:@"_isPlayingAudio"]) {
        BOOL playing = NO; @try { playing = [[_web valueForKey:@"_isPlayingAudio"] boolValue]; } @catch (NSException *x) {}
        self.tab.audible = playing; [PW.sidebar setNeedsDisplay:YES];
        if (playing && self.tab) PW.mediaTab = self.tab;
        [PW updateNowPlaying]; return;
    }
    else if ([k isEqualToString:@"estimatedProgress"]) { if (fabs(_web.estimatedProgress - self.progress) < 0.03 && _web.estimatedProgress < 1) return; self.progress = _web.estimatedProgress; }
    [PW pageChanged:self];
}

#pragma mark Navigation

// Flint marks a page as loading the moment you ask for it; WebKit's own flag decides when it's done. Some loads
// (restored sessions, pages served from cache, single-page sites) finish without the change Flint listens for,
// so while a page shows as loading this re-checks WebKit every 1.5 s and stops the bar when WebKit has.
- (void)watchLoading {
    if (_watchingLoad) return;
    _watchingLoad = YES;
    __weak VPage *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        VPage *p = ws; if (!p) return;
        p->_watchingLoad = NO;
        if (!p.loading) return;
        if (!p.web.isLoading && p.web.estimatedProgress > 0.05) { p.loading = NO; p.progress = 1; [p.tab.owner pageChanged:p]; return; }
        [p watchLoading];
    });
}

- (BOOL)canGoBack { return _web.canGoBack || _back.count > 0; }
- (BOOL)canGoForward { return _web.canGoForward; }

- (void)open:(NSString *)url record:(BOOL)record {
    if (!url.length) return;
    NSURL *u = [NSURL URLWithString:url]; if (!u) return;
    self.url = url; self.loading = YES; self.progress = 0.05; [self watchLoading];
    if ([u.scheme isEqualToString:@"view-source"]) { [self showSource:[NSURL URLWithString:[url substringFromIndex:12]]]; return; }
    if (u.isFileURL) [_web loadFileURL:u allowingReadAccessToURL:u.URLByDeletingLastPathComponent];
    else [_web loadRequest:[NSURLRequest requestWithURL:u]];
    [PW pageChanged:self];
}

// view-source: isn't a WebKit scheme, so fetch the page and show it as text
- (void)showSource:(NSURL *)u {
    if (!u) return;
    [[NSURLSession.sharedSession dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *s = d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"") : e.localizedDescription;
        s = [[[s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"] stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"] stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
        NSString *html = [NSString stringWithFormat:@"<!doctype html><meta charset=utf-8><title>Source of %@</title><style>html{background:#1b1b1d;color:#d6d6da}pre{font:12px ui-monospace,Menlo;white-space:pre-wrap;word-break:break-all;padding:16px}</style><pre>%@</pre>", u.host, s];
        dispatch_async(dispatch_get_main_queue(), ^{ [self->_web loadHTMLString:html baseURL:nil]; self.loading = NO; [PW pageChanged:self]; });
    }] resume];
}

- (void)goBack {
    if (_web.canGoBack) { [_web goBack]; return; }
    if (!_back.count) return;
    NSString *u = _back.lastObject; [_back removeLastObject];
    [self open:u record:NO];
}
- (void)goForward { [_web goForward]; }
- (void)reload { if (_web.URL) [_web reload]; else if (self.url) [self open:self.url record:NO]; }
- (void)hardReload { [_web reloadFromOrigin]; }
- (void)stop { [_web stopLoading]; }

- (NSArray<NSString *> *)historyForSleep {
    NSMutableArray *a = [_back mutableCopy];
    for (WKBackForwardListItem *i in _web.backForwardList.backList) [a addObject:i.URL.absoluteString];
    while (a.count > 50) [a removeObjectAtIndex:0];
    return a;
}

#pragma mark WKNavigationDelegate

static NSMutableSet<NSString *> *gHTTPAllowed;   // hosts you chose to open over plain HTTP this session

- (void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)a preferences:(WKWebpagePreferences *)prefs decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decide {
    NSURL *u = a.request.URL;
    _lastMethod = a.request.HTTPMethod ?: @"GET";
    // JavaScript: on everywhere unless you turned it off globally or for this site
    if (a.targetFrame.isMainFrame) {
        NSString *h = HostOf(u);
        prefs.allowsContentJavaScript = [Defaults() boolForKey:kScripts] && !(h.length && [[Defaults() arrayForKey:kJSOff] containsObject:h]);
        // The tab coming back at launch: WebKit itself refuses playback (Safari's "Never Auto-Play") for this one
        // page until you click or press a key in it, so nothing can start before Flint's own hold arrives.
        if (self.tab.launchRestored && [u.scheme hasPrefix:@"http"]) {
            SEL s = NSSelectorFromString(@"_setAutoplayPolicy:");
            if ([prefs respondsToSelector:s]) { ((void (*)(id, SEL, NSUInteger))objc_msgSend)(prefs, s, 3); DLog(@"launch: WebKit autoplay denied for %@", HostOf(u)); }   // _WKWebsiteAutoplayPolicyDeny
            else DLog(@"launch: WebKit autoplay policy unavailable, script hold only");
        }
    }
    // "Continue to the HTTP site" from the HTTPS-only page
    // "visit anyway" on the certificate warning: only a click on that warning, for that host, counts
    if ([u.scheme isEqualToString:@"flint-cert"]) {
        BOOL ok = u.host.length && a.navigationType == WKNavigationTypeLinkActivated && a.targetFrame.isMainFrame && [_certErrorFor isEqualToString:u.host.lowercaseString];
        if (!ok) { decide(WKNavigationActionPolicyCancel, prefs); return; }
        if (!gCertOK) gCertOK = [NSMutableSet set];
        [gCertOK addObject:u.host.lowercaseString];
        NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO]; c.scheme = @"https";
        decide(WKNavigationActionPolicyCancel, prefs);
        [w loadRequest:[NSURLRequest requestWithURL:c.URL]];
        return;
    }
    if ([u.scheme isEqualToString:@"flint-http"]) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO]; c.scheme = @"http";
        if (!gHTTPAllowed) gHTTPAllowed = [NSMutableSet set];
        if (c.host) [gHTTPAllowed addObject:c.host];
        decide(WKNavigationActionPolicyCancel, prefs); [w loadRequest:[NSURLRequest requestWithURL:c.URL]]; return;
    }
    // HTTPS-only: plain-HTTP pages are tried over HTTPS first
    if (a.targetFrame.isMainFrame && [u.scheme isEqualToString:@"http"] && [Defaults() boolForKey:kHTTPSOnly] && u.host &&
        ![gHTTPAllowed containsObject:u.host] && ![u.host isEqualToString:@"localhost"] && ![u.host hasSuffix:@".local"] &&
        [u.host rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO]; c.scheme = @"https";
        _httpsUpgradeOf = u;
        decide(WKNavigationActionPolicyCancel, prefs); [w loadRequest:[NSURLRequest requestWithURL:c.URL]]; return;
    }
    [self webView:w decideAction:a done:^(WKNavigationActionPolicy p) { decide(p, prefs); }];
}

- (void)webView:(WKWebView *)w decideAction:(WKNavigationAction *)a done:(void (^)(WKNavigationActionPolicy))done {
    NSURL *u = a.request.URL;
    NSString *scheme = u.scheme.lowercaseString;
    BOOL main = a.targetFrame.isMainFrame;
    // ⇧-click: peek at the link without leaving the page
    if (a.navigationType == WKNavigationTypeLinkActivated && (a.modifierFlags & NSEventModifierFlagShift) && !(a.modifierFlags & NSEventModifierFlagCommand) && [u.scheme hasPrefix:@"http"]) {
        [PW peekURL:u]; done(WKNavigationActionPolicyCancel); return;
    }
    // ⌘-click and middle-click open tabs
    if (a.navigationType == WKNavigationTypeLinkActivated && ((a.modifierFlags & NSEventModifierFlagCommand) || a.buttonNumber == 2)) {
        [PW newTab:u select:(a.modifierFlags & NSEventModifierFlagShift) != 0];
        done(WKNavigationActionPolicyCancel); return;
    }
    if (a.shouldPerformDownload) { done(WKNavigationActionPolicyDownload); return; }
    if (scheme && ![@[@"http", @"https", @"file", @"about", @"data", @"blob", @"chrome-extension", @"javascript", @"flint-http", @"flint-cert", @"flint"] containsObject:scheme]) {
        if (main || a.navigationType == WKNavigationTypeLinkActivated) [NSWorkspace.sharedWorkspace openURL:u];   // mailto:, zoommtg:, apps
        done(WKNavigationActionPolicyCancel); return;
    }
    // tracking tags (utm_, fbclid…) come off before the page loads
    if (main && [a.request.HTTPMethod isEqualToString:@"GET"] && [Defaults() boolForKey:kStrip]) {
        NSURL *clean = StripTracking(u);
        if (clean) { done(WKNavigationActionPolicyCancel); [w loadRequest:[NSURLRequest requestWithURL:clean]]; return; }
    }
    done(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)w decidePolicyForNavigationResponse:(WKNavigationResponse *)r decisionHandler:(void (^)(WKNavigationResponsePolicy))done {
    NSString *disp = [(NSHTTPURLResponse *)r.response respondsToSelector:@selector(valueForHTTPHeaderField:)] ? [(NSHTTPURLResponse *)r.response valueForHTTPHeaderField:@"Content-Disposition"] : nil;
    BOOL isDownload = !r.canShowMIMEType || [disp.lowercaseString hasPrefix:@"attachment"];
    if (!isDownload) { done(WKNavigationResponsePolicyAllow); return; }
    // Flint's accelerator takes plain GET downloads over http(s); everything else stays with WebKit
    NSURL *u = r.response.URL;
    BOOL ask = [Defaults() boolForKey:kAskDownload] || gAskNextDownload;
    if ([Defaults() boolForKey:kDLAccel] && !ask && [@[@"http", @"https"] containsObject:u.scheme.lowercaseString ?: @""] && [(_lastMethod ?: @"GET") isEqualToString:@"GET"]) {
        done(WKNavigationResponsePolicyCancel);
        NSString *ref = _web.URL && ![_web.URL isEqual:u] ? _web.URL.absoluteString : nil;
        [FAccel.shared downloadURL:u name:r.response.suggestedFilename referer:ref view:_web private:self.tab.owner.isPrivate];
        [self closeIfOnlyDownload];
        return;
    }
    done(WKNavigationResponsePolicyDownload);
}

- (void)webView:(WKWebView *)w navigationAction:(WKNavigationAction *)a didBecomeDownload:(WKDownload *)d { d.delegate = self; [self closeIfOnlyDownload]; }
- (void)webView:(WKWebView *)w navigationResponse:(WKNavigationResponse *)r didBecomeDownload:(WKDownload *)d { d.delegate = self; [self closeIfOnlyDownload]; }
// A tab opened only to fetch a file (a link with target=_blank, a typed file URL) closes once the download starts, as in Chrome.
- (void)closeIfOnlyDownload {
    if (_web.backForwardList.currentItem || _back.count) return;
    __weak VTab *t = self.tab;
    dispatch_async(dispatch_get_main_queue(), ^{ if (t && [PW.tabs containsObject:t]) [PW closeTab:t]; });
}

- (void)webView:(WKWebView *)w didCommitNavigation:(WKNavigation *)n { _httpsUpgradeOf = nil; if (![HostOf(w.URL) isEqualToString:_certErrorFor ?: @""] && ![w.URL.host.lowercaseString isEqualToString:_certErrorFor ?: @""]) _certErrorFor = nil; [FExtHost.shared tab:self.tab event:@"loading"]; [self holdLaunchPlayback]; }
// The tab you had open at launch comes back paused, and stays paused until you click or press a key on it.
// Playback is refused the way a browser's autoplay block refuses it (the page's play() is turned down with
// "not allowed"), so YouTube shows its play button instead of starting and being stopped a moment later.
- (void)holdLaunchPlayback {
    if (!self.tab.launchRestored || ![_web.URL.scheme hasPrefix:@"http"]) return;
    self.tab.launchRestored = NO;
    DLog(@"launch: holding playback in %@ until you interact", HostOf(_web.URL));
    [_web evaluateJavaScript:@"(()=>{if(window.__flintHold)return;window.__flintHold=1;let hold=true;const P=HTMLMediaElement.prototype,op=P.play;"
        "P.play=function(){if(hold){try{this.pause()}catch(e){}return Promise.reject(new DOMException('Playback starts when you click','NotAllowedError'))}return op.apply(this,arguments)};"
        "const you=e=>{if(!e.isTrusted)return;hold=false;for(const t of['pointerdown','keydown'])removeEventListener(t,you,true)};"
        "for(const t of['pointerdown','keydown'])addEventListener(t,you,true);"
        "document.addEventListener('play',e=>{if(hold&&e.target&&e.target.pause)e.target.pause()},true);"
        "for(const v of document.querySelectorAll('video,audio'))if(!v.paused)v.pause()})()" completionHandler:nil];
}
- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)n {
    if (!w.isLoading && self.loading) { self.loading = NO; self.progress = 1; [PW pageChanged:self]; }
    [self checkVideo];
    [self resumeMedia];
    [FExtHost.shared tab:self.tab event:@"complete"];
    [self findIcon];
    NSNumber *z = [Defaults() dictionaryForKey:kZoom][HostOf(w.URL)] ?: [Defaults() objectForKey:kDefaultZoom];
    if (z && fabs(z.doubleValue - _zoom) > 0.01) [self setZoomLevel:z.doubleValue];
}
- (void)webView:(WKWebView *)w didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e { [self showError:e]; }
- (void)webView:(WKWebView *)w didFailNavigation:(WKNavigation *)n withError:(NSError *)e { [self showError:e]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)w { [w reload]; }

static NSString *ErrEsc(NSString *s) {
    return [[[[s ?: @"" stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"] stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
             stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"] stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
}
static NSString *ErrorPage(NSString *title, NSString *heading, NSString *body, NSString *actions, NSString *detail) {
    return [NSString stringWithFormat:@"<!doctype html><meta charset=utf-8><title>%@</title><style>%@html{background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,system-ui}"
        "main{max-width:560px;margin:16vh auto;padding:0 24px}h1{font-size:23px;font-weight:600;margin:14px 0 8px;letter-spacing:-.01em}p{color:var(--dim);margin:0 0 12px}"
        ".ic{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;background:var(--card);border:1px solid var(--border);font-size:22px}"
        ".acts{display:flex;gap:10px;flex-wrap:wrap;margin:22px 0}.acts a{padding:8px 16px;border-radius:999px;text-decoration:none;font-weight:600;font-size:13.5px;border:1px solid var(--border);color:var(--text);background:var(--pill)}"
        ".acts a.primary{background:var(--accent);color:var(--onaccent);border-color:transparent}details{color:var(--faint);font-size:12.5px}summary{cursor:pointer;color:var(--dim)}"
        "details a{color:var(--accent)}code{font:12px ui-monospace,Menlo;color:var(--faint);word-break:break-all}</style><main>%@<h1>%@</h1>%@<div class=acts>%@</div>%@</main>",
        ErrEsc(title), ThemeCSS(), @"", ErrEsc(heading), body, actions, detail ?: @""];
}

- (void)showError:(NSError *)e {
    if ([e.domain isEqualToString:NSURLErrorDomain] && e.code == NSURLErrorCancelled) return;
    NSURL *wanted = _httpsUpgradeOf; _httpsUpgradeOf = nil;
    if (wanted) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:wanted resolvingAgainstBaseURL:NO]; c.scheme = @"flint-http";
        NSString *html = ErrorPage(@"Not secure", [NSString stringWithFormat:@"%@ doesn't offer a secure connection", wanted.host],
            @"<p>HTTPS-only mode is on, so Flint didn't open the insecure version. Anyone on your network could see or change what you send there.</p>",
            [NSString stringWithFormat:@"<a class=primary href=\"javascript:history.back()\">Go Back</a><a href=\"%@\">Continue to the HTTP Site</a>", ErrEsc(c.URL.absoluteString)], nil);
        [_web loadHTMLString:html baseURL:nil];
        self.loading = NO; self.title = wanted.host; self.url = wanted.absoluteString; [PW pageChanged:self];
        return;
    }
    if ([e.domain isEqualToString:@"WebKitErrorDomain"] && (e.code == 102 || e.code == 204)) return;   // frame load interrupted by policy / plug-in handled
    NSURL *failed = e.userInfo[NSURLErrorFailingURLErrorKey] ?: [NSURL URLWithString:self.url ?: @""];
    NSString *host = failed.host ?: @"This page";
    // certificate problems: WebKit reports most of them as a generic SSL error (-1200) carrying the server's trust
    BOOL ssl = [e.domain isEqualToString:NSURLErrorDomain] && e.code <= NSURLErrorSecureConnectionFailed && e.code >= NSURLErrorClientCertificateRequired;
    id trustObj = e.userInfo[NSURLErrorFailingURLPeerTrustErrorKey];
    NSInteger stream = [e.userInfo[@"_kCFStreamErrorCodeKey"] integerValue];
    int kind = 0;   // 1 expired, 2 untrusted, 3 wrong host, 4 other certificate problem
    if (ssl && e.code != NSURLErrorClientCertificateRejected && e.code != NSURLErrorClientCertificateRequired) {
        if (e.code == NSURLErrorServerCertificateHasBadDate || stream == -9814 || stream == -9815) kind = 1;
        else if (e.code == NSURLErrorServerCertificateUntrusted || e.code == NSURLErrorServerCertificateHasUnknownRoot || stream == -9807 || stream == -9812 || stream == -9813) kind = 2;
        else if (stream == -9843) kind = 3;
        if (trustObj && CFGetTypeID((__bridge CFTypeRef)trustObj) == SecTrustGetTypeID()) {
            CFErrorRef te = NULL;
            if (!SecTrustEvaluateWithError((__bridge SecTrustRef)trustObj, &te) && te) {
                CFIndex c = CFErrorGetCode(te);
                kind = (c == errSecCertificateExpired || c == errSecCertificateNotValidYet) ? 1 : c == errSecHostNameMismatch ? 3 : (c == errSecNotTrusted || c == errSecCreateChainFailed) ? 2 : (kind ?: 4);
            }
            if (te) CFRelease(te);
        }
    }
    BOOL cert = ssl;
    NSString *html;
    if (kind) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:failed resolvingAgainstBaseURL:NO]; c.scheme = @"flint-cert";
        _certErrorFor = failed.host.lowercaseString;
        NSString *why = kind == 1 ? @"Its security certificate has expired or isn't valid yet." :
                        kind == 2 ? @"Its security certificate isn't trusted by this Mac — it may be self-signed or issued by an unknown authority." :
                        kind == 3 ? [NSString stringWithFormat:@"Its security certificate is for a different site, not %@.", host] :
                        @"Its security certificate couldn't be verified.";
        html = ErrorPage(@"Privacy error", [NSString stringWithFormat:@"Your connection to %@ isn't private", host],
            [NSString stringWithFormat:@"<p>%@ Someone could be trying to read or change what you send to this site, such as passwords or card numbers.</p>", ErrEsc(why)],
            @"<a class=primary href=\"javascript:history.length>1?history.back():location.replace('about:blank')\">Back to Safety</a>",
            [NSString stringWithFormat:@"<details><summary>Details</summary><p><code>%@ (%ld)</code></p><p>If you understand the risk — for example, it's a device on your own network — you can <a href=\"%@\">visit %@ anyway</a>. Flint will allow it until you quit.</p></details>",
             ErrEsc(e.localizedDescription), (long)e.code, ErrEsc(c.URL.absoluteString), ErrEsc(host)]);
    } else {
        NSString *why = e.code == NSURLErrorCannotFindHost ? @"Flint couldn't find this site. Check the address for typos, or your connection." :
                        e.code == NSURLErrorNotConnectedToInternet ? @"You're offline. Check your Wi-Fi or network cable." :
                        e.code == NSURLErrorTimedOut ? @"The site took too long to respond." :
                        e.code == NSURLErrorCannotConnectToHost ? @"The site refused the connection." :
                        e.code == NSURLErrorNetworkConnectionLost ? @"The network connection was lost." :
                        cert ? @"A secure connection to this site couldn't be made." :
                        @"The page couldn't be loaded.";
        NSString *heading = e.code == NSURLErrorNotConnectedToInternet ? @"No internet connection" : e.code == NSURLErrorCannotFindHost ? [NSString stringWithFormat:@"Can't find %@", host] : [NSString stringWithFormat:@"%@ can't be reached", host];
        html = ErrorPage(host, heading, [NSString stringWithFormat:@"<p>%@</p>", ErrEsc(why)],
            [NSString stringWithFormat:@"<a class=primary href=\"%@\">Try Again</a>", ErrEsc(failed.absoluteString)],
            [NSString stringWithFormat:@"<details><summary>Details</summary><p><code>%@ (%ld)</code></p></details>", ErrEsc(e.localizedDescription), (long)e.code]);
    }
    [_web loadHTMLString:html baseURL:failed];
    self.loading = NO; self.title = host; self.url = failed.absoluteString;
    [PW pageChanged:self];
}

- (void)webView:(WKWebView *)w didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)ch completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))done {
    if ([ch.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] && ch.protectionSpace.serverTrust &&
        [gCertOK containsObject:ch.protectionSpace.host.lowercaseString ?: @""]) {
        done(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:ch.protectionSpace.serverTrust]); return;
    }
    if ([@[NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] containsObject:ch.protectionSpace.authenticationMethod]) {
        if (ch.previousFailureCount > 2) { done(NSURLSessionAuthChallengeRejectProtectionSpace, nil); return; }
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Sign in to %@", ch.protectionSpace.host];
        a.informativeText = ch.protectionSpace.realm.length ? [NSString stringWithFormat:@"The site says: “%@”%@", ch.protectionSpace.realm, ch.protectionSpace.receivesCredentialSecurely ? @"" : @"\nThis connection isn't secure — your password would be sent in the clear."] : @"This site needs a username and password.";
        NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 58)];
        NSTextField *user = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 32, 260, 24)]; user.placeholderString = @"Username";
        NSSecureTextField *pass = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)]; pass.placeholderString = @"Password";
        user.stringValue = ch.proposedCredential.user ?: @""; user.nextKeyView = pass;
        [box addSubview:user]; [box addSubview:pass]; a.accessoryView = box;
        [a addButtonWithTitle:@"Sign In"]; [a addButtonWithTitle:@"Cancel"];
        a.window.initialFirstResponder = user;
        [a beginSheetModalForWindow:self.window ?: PW.window completionHandler:^(NSModalResponse r) {
            if (r == NSAlertFirstButtonReturn) done(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialWithUser:user.stringValue password:pass.stringValue persistence:NSURLCredentialPersistenceForSession]);
            else done(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        }];
        return;
    }
    done(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

// The page's own icon (<link rel=icon>, best size), so every site gets its real icon in the sidebar.
- (void)findIcon {
    VTab *t = self.tab; NSURL *page = _web.URL;
    if (!t || !page) return;
    if ([page.scheme isEqualToString:@"chrome-extension"]) { t.favicon = [FExtHost.shared iconForID:page.host]; [PW refreshChrome]; return; }
    if ([page.scheme isEqualToString:@"flint"]) {
        NSString *sym = @{@"bookmarks": @"book", @"history": @"clock.arrow.circlepath", @"reader": @"doc.plaintext", @"downloads": @"arrow.down.circle", @"settings": @"gearshape"}[page.host] ?: @"flame";
        t.favicon = Tinted(Symbol(sym, 13, NSFontWeightMedium), vDim); [PW refreshChrome]; return;
    }
    if (![page.scheme hasPrefix:@"http"]) return;
    NSImage *known = [VFavicons.shared iconForURL:page.absoluteString];
    if (known) { if (t.favicon != known) { t.favicon = known; [PW refreshChrome]; } return; }
    if (t.owner.isPrivate) return;   // private windows don't leave site icons behind
    NSString *js = @"(()=>{let best=null,score=-1;for(const l of document.querySelectorAll('link[rel~=\"icon\"],link[rel=\"apple-touch-icon\"],link[rel=\"shortcut icon\"]')){"
                   "if(!l.href)continue;const svg=/svg/.test(l.type||'')||/\\.svg($|\\?)/.test(l.href);const apple=/apple/.test(l.rel);const sz=parseInt(((l.sizes&&l.sizes.value)||'').split('x')[0])||(apple?180:16);"
                   "const s=apple?1:svg?400:(sz>=32&&sz<=256?100+sz:10+Math.min(sz,64));if(s>score){score=s;best=l.href}}return best})()";
    __weak VTab *wt = t;
    [_web evaluateJavaScript:js completionHandler:^(id href, NSError *e) {
        [VFavicons.shared fetchFor:page href:[href isKindOfClass:NSString.class] ? href : nil done:^(NSImage *im) {
            if (wt && [HostOf([NSURL URLWithString:wt.url ?: @""]) isEqualToString:HostOf(page)]) { wt.favicon = im; [PW refreshChrome]; [PW.bookmarksBar reload]; }
        }];
    }];
}

#pragma mark Sound and video

- (void)setMuted:(BOOL)m {
    SEL s = NSSelectorFromString(@"_setPageMuted:");   // WebKit's tab mute (what Safari uses)
    if ([_web respondsToSelector:s]) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(_web, s, m ? 1 : 0);
    else [_web evaluateJavaScript:[NSString stringWithFormat:@"document.querySelectorAll('video,audio').forEach(v=>v.muted=%@)", m ? @"true" : @"false"] completionHandler:nil];
    self.tab.muted = m; [PW.sidebar setNeedsDisplay:YES];
}
// Whether this page has a video worth floating (loaded, at least 160 px wide), and whether one is floating now.
- (void)checkVideo {
    if (![_web.URL.scheme hasPrefix:@"http"]) { if (self.tab.hasVideo) { self.tab.hasVideo = NO; self.tab.inPiP = NO; [PW refreshChrome]; } return; }
    __weak VPage *ws = self;
    [_web evaluateJavaScript:@"(()=>{const v=[...document.querySelectorAll('video')].some(v=>v.readyState>0&&v.getBoundingClientRect().width>=160);"
                              "const p=!!document.pictureInPictureElement||[...document.querySelectorAll('video')].some(v=>v.webkitPresentationMode==='picture-in-picture');return (v||p?1:0)+(p?2:0)})()"
           completionHandler:^(id r, NSError *e) {
        VPage *p = ws; if (!p || ![r isKindOfClass:NSNumber.class]) return;
        BOOL v = ([r intValue] & 1) != 0, pip = ([r intValue] & 2) != 0;
        if (v != p.tab.hasVideo || pip != p.tab.inPiP) { p.tab.hasVideo = v; p.tab.inPiP = pip; [p.tab.owner refreshChrome]; }
    }];
}
// Which video a time belongs to: a YouTube watch page is its video id, anything else its address without the #part.
static NSString *MediaKey(NSURL *u) {
    if (!u) return @"";
    NSString *h = u.host.lowercaseString ?: @"";
    if ([h hasSuffix:@"youtube.com"] && [u.path hasPrefix:@"/watch"])
        for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO].queryItems) if ([q.name isEqualToString:@"v"]) return [@"yt:" stringByAppendingString:q.value ?: @""];
    if ([h isEqualToString:@"youtu.be"]) return [@"yt:" stringByAppendingString:[u.path stringByReplacingOccurrencesOfString:@"/" withString:@""]];
    NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO]; c.fragment = nil;
    return c.string ?: @"";
}
// Remember how far into the main video you are (videos over a minute, not ads, not live streams).
- (void)noteMediaTime {
    VTab *t = self.tab;
    if (!t || t.resumeAt > 0 || ![_web.URL.scheme hasPrefix:@"http"] || ![Defaults() boolForKey:kResumeMedia]) return;
    if (((VWindow *)t.owner).isPrivate) return;
    __weak VPage *ws = self;
    [_web evaluateJavaScript:@"(()=>{const mp=document.getElementById('movie_player');if(mp&&mp.classList.contains('ad-showing'))return null;"
        "if(mp&&mp.getCurrentTime&&mp.getDuration&&mp.getDuration()>=60)return[mp.getCurrentTime(),mp.getDuration()];"
        "const v=[...document.querySelectorAll('video')].filter(v=>v.readyState>0&&isFinite(v.duration)&&v.duration>=60).sort((a,b)=>b.videoWidth*b.videoHeight-a.videoWidth*a.videoHeight)[0];"
        "return v?[v.currentTime,v.duration]:null})()" completionHandler:^(id r, NSError *e) {
        VPage *p = ws; VTab *t = p.tab;
        if (!p || !t || t.resumeAt > 0 || ![r isKindOfClass:NSArray.class] || [r count] != 2) return;
        double now = [r[0] doubleValue], len = [r[1] doubleValue];
        NSString *key = MediaKey(p.web.URL);
        if (now < 10 || now > len - 15) { if ([key isEqualToString:t.mediaKey]) t.mediaTime = 0; }   // at the start, or finished: nothing to come back to
        else { t.mediaTime = now; t.mediaKey = key; }
        if (fabs(t.mediaTime - t.savedMedia) >= 10) { t.savedMedia = t.mediaTime; [t.owner scheduleSave]; DLog(@"video position noted: %.0f s", t.mediaTime); }
    }];
}
// Put the video back where it was (after a restart, or when a sleeping tab wakes). YouTube resets its player as
// it starts, so the seek is repeated until the video has stayed at that point for a moment.
- (void)resumeMedia {
    VTab *t = self.tab; double at = t.resumeAt;
    if (at <= 0 || t.resuming || ![_web.URL.scheme hasPrefix:@"http"]) return;
    if (![MediaKey(_web.URL) isEqualToString:t.mediaKey ?: @""]) { DLog(@"video resume skipped: now %@, saved %@", MediaKey(_web.URL), t.mediaKey); t.resumeAt = 0; return; }
    t.resuming = YES;
    DLog(@"resuming video in %@ at %.0f s", HostOf(_web.URL), at);
    [_web evaluateJavaScript:[NSString stringWithFormat:@"(()=>{const T=%.2f;let n=0,ok=0;const go=()=>{const mp=document.getElementById('movie_player');"
        "const v=[...document.querySelectorAll('video')].filter(v=>v.readyState>0&&isFinite(v.duration)&&v.duration>T).sort((a,b)=>b.videoWidth*b.videoHeight-a.videoWidth*a.videoHeight)[0];"
        "const yt=mp&&mp.seekTo&&mp.getDuration&&mp.getDuration()>T,ad=mp&&mp.classList.contains('ad-showing');"
        "if(!ad&&(yt||v)){const c=yt?mp.getCurrentTime():v.currentTime;if(Math.abs(c-T)<3){if(++ok>=4)return}else{ok=0;if(yt)mp.seekTo(T,true);else v.currentTime=T}}"
        "if(++n<60)setTimeout(go,500)};go()})()", at] completionHandler:nil];
    __weak VTab *wt = t;   // after half a minute it's yours again: stop guarding and start remembering
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 31 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ wt.resumeAt = 0; wt.resuming = NO; });
}
- (void)pictureInPicture {
    [_web evaluateJavaScript:@"(()=>{const v=[...document.querySelectorAll('video')].sort((a,b)=>(b.videoWidth*b.videoHeight)-(a.videoWidth*a.videoHeight))[0];if(!v)return 'none';"
                             "if(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')){v.webkitSetPresentationMode(v.webkitPresentationMode==='picture-in-picture'?'inline':'picture-in-picture');return 'ok'}"
                             "if(document.pictureInPictureElement){document.exitPictureInPicture();return 'ok'}v.requestPictureInPicture();return 'ok'})()"
           completionHandler:^(id r, NSError *e) {
        if ([r isEqual:@"none"]) [PW showToast:@"No video on this page"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self checkVideo]; });
    }];
}

#pragma mark Session state

- (id)sessionState { return _web.interactionState; }
- (void)restoreState:(id)state url:(NSString *)url {
    if (state) {
        @try {
            _web.interactionState = state; self.url = url; self.loading = YES; [self watchLoading]; [PW pageChanged:self];
            // some saved states (an error page, a page that was mid-redirect) restore to nothing: load the address instead
            __weak VPage *ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                VPage *p = ws;
                if (p && p.loading && !p.web.isLoading && p.web.estimatedProgress < 0.01 && url.length) [p open:url record:NO];
            });
            return;
        } @catch (NSException *x) {}
    }
    [self open:url record:NO];
}

#pragma mark WKUIDelegate: popups become tabs (window.opener keeps working), dialogs, file pickers

- (WKWebView *)webView:(WKWebView *)w createWebViewWithConfiguration:(WKWebViewConfiguration *)c forNavigationAction:(WKNavigationAction *)a windowFeatures:(WKWindowFeatures *)f {
    FWebView *nw = [[FWebView alloc] initWithFrame:self.bounds configuration:c];
    VPage *p = [[VPage alloc] initWithFrame:self.bounds web:nw];
    [PW newTabWithPage:p url:a.request.URL select:YES];
    return nw;
}
- (void)webViewDidClose:(WKWebView *)w { if (self.tab) [PW closeTab:self.tab]; }

- (void)webView:(WKWebView *)w runJavaScriptAlertPanelWithMessage:(NSString *)m initiatedByFrame:(WKFrameInfo *)f completionHandler:(void (^)(void))done {
    NSAlert *a = [NSAlert new]; a.messageText = f.request.URL.host ?: @"This page says"; a.informativeText = m ?: @"";
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { done(); }];
}
- (void)webView:(WKWebView *)w runJavaScriptConfirmPanelWithMessage:(NSString *)m initiatedByFrame:(WKFrameInfo *)f completionHandler:(void (^)(BOOL))done {
    NSAlert *a = [NSAlert new]; a.messageText = f.request.URL.host ?: @"This page asks"; a.informativeText = m ?: @"";
    [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { done(r == NSAlertFirstButtonReturn); }];
}
- (void)webView:(WKWebView *)w runJavaScriptTextInputPanelWithPrompt:(NSString *)p defaultText:(NSString *)d initiatedByFrame:(WKFrameInfo *)f completionHandler:(void (^)(NSString *))done {
    NSAlert *a = [NSAlert new]; a.messageText = f.request.URL.host ?: @"This page asks"; a.informativeText = p ?: @"";
    NSTextField *t = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)]; t.stringValue = d ?: @""; a.accessoryView = t;
    [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { done(r == NSAlertFirstButtonReturn ? t.stringValue : nil); }];
}
- (void)webView:(WKWebView *)w runOpenPanelWithParameters:(WKOpenPanelParameters *)p initiatedByFrame:(WKFrameInfo *)f completionHandler:(void (^)(NSArray<NSURL *> *))done {
    NSOpenPanel *o = [NSOpenPanel openPanel];
    o.allowsMultipleSelection = p.allowsMultipleSelection; o.canChooseDirectories = p.allowsDirectories; o.canChooseFiles = YES;
    [o beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { done(r == NSModalResponseOK ? o.URLs : nil); }];
}
- (void)webView:(WKWebView *)w requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)o initiatedByFrame:(WKFrameInfo *)f type:(WKMediaCaptureType)t decisionHandler:(void (^)(WKPermissionDecision))done API_AVAILABLE(macos(12.0)) {
    NSString *host = o.host.lowercaseString ?: @"";
    NSString *kind = t == WKMediaCaptureTypeCamera ? @"camera" : t == WKMediaCaptureTypeMicrophone ? @"microphone" : @"camera+microphone";
    NSDictionary *perms = [Defaults() dictionaryForKey:kSitePerms][host];
    NSArray *keys = [kind isEqualToString:@"camera+microphone"] ? @[@"camera", @"microphone"] : @[kind];
    BOOL allAllowed = YES, anyBlocked = NO;
    for (NSString *k in keys) { NSInteger v = [perms[k] integerValue]; if (v != 1) allAllowed = NO; if (v == 2) anyBlocked = YES; }
    if (anyBlocked) { done(WKPermissionDecisionDeny); return; }
    if (allAllowed) { done(WKPermissionDecisionGrant); return; }
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"%@ wants to use your %@", host, [kind stringByReplacingOccurrencesOfString:@"+" withString:@" and "]];
    a.informativeText = @"You can change this later in Settings ▸ Site Settings.";
    [a addButtonWithTitle:@"Allow"]; [a addButtonWithTitle:@"Don't Allow"];
    a.showsSuppressionButton = YES; a.suppressionButton.title = @"Remember for this site"; a.suppressionButton.state = NSControlStateValueOn;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        BOOL allow = r == NSAlertFirstButtonReturn;
        if (a.suppressionButton.state == NSControlStateValueOn) {
            NSMutableDictionary *all = [[Defaults() dictionaryForKey:kSitePerms] ?: @{} mutableCopy];
            NSMutableDictionary *mine = [all[host] ?: @{} mutableCopy];
            for (NSString *k in keys) mine[k] = @(allow ? 1 : 2);
            all[host] = mine; [Defaults() setObject:all forKey:kSitePerms];
        }
        done(allow ? WKPermissionDecisionGrant : WKPermissionDecisionDeny);
    }];
}

#pragma mark Downloads

- (void)download:(WKDownload *)d decideDestinationUsingResponse:(NSURLResponse *)r suggestedFilename:(NSString *)name completionHandler:(void (^)(NSURL *))done {
    NSString *base = name.length ? name : @"download";
    NSURL *dir = PW.downloadFolder;
    void (^go)(NSURL *) = ^(NSURL *dest) {
        done(dest);
        if (dest) { [VDownloads.shared startFor:d dest:dest]; [PW showToast:[NSString stringWithFormat:@"Downloading %@…", dest.lastPathComponent]]; }
    };
    BOOL ask = [Defaults() boolForKey:kAskDownload] || gAskNextDownload; gAskNextDownload = NO;
    if (ask) {
        NSSavePanel *p = [NSSavePanel savePanel]; p.nameFieldStringValue = base; p.directoryURL = dir;
        [p beginSheetModalForWindow:PW.window completionHandler:^(NSModalResponse res) { go(res == NSModalResponseOK ? p.URL : nil); }];
        return;
    }
    NSURL *dest = [dir URLByAppendingPathComponent:base];
    for (int n = 1; [NSFileManager.defaultManager fileExistsAtPath:dest.path]; n++)
        dest = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d%@", base.stringByDeletingPathExtension, n, base.pathExtension.length ? [@"." stringByAppendingString:base.pathExtension] : @""]];
    go(dest);
}
- (void)downloadDidFinish:(WKDownload *)d { [VDownloads.shared finished:d]; }
- (void)download:(WKDownload *)d didFailWithError:(NSError *)e resumeData:(NSData *)r { [VDownloads.shared failed:d resume:r]; if (!(e.code == NSURLErrorCancelled)) [PW showToast:@"Download failed"]; }

- (void)download:(NSString *)url {
    NSURL *u = [NSURL URLWithString:url]; if (!u) return;
    if ([Defaults() boolForKey:kDLAccel] && !gAskNextDownload && ![Defaults() boolForKey:kAskDownload] && [@[@"http", @"https"] containsObject:u.scheme.lowercaseString ?: @""]) {
        [FAccel.shared downloadURL:u name:nil referer:_web.URL.absoluteString view:_web private:self.tab.owner.isPrivate];
        return;
    }
    [_web startDownloadUsingRequest:[NSURLRequest requestWithURL:u] completionHandler:^(WKDownload *d) { d.delegate = self; }];
}

#pragma mark Editing, zoom, find, misc

- (void)paste:(id)s { [NSApp sendAction:@selector(paste:) to:_web from:s]; }
- (void)setZoomLevel:(CGFloat)z { _zoom = z; _web.pageZoom = z; }

- (void)find:(NSString *)q forward:(BOOL)fwd next:(BOOL)next {
    if (!q.length) return;
    WKFindConfiguration *c = [WKFindConfiguration new];
    c.backwards = !fwd; c.wraps = YES; c.caseSensitive = NO;
    [_web findString:q withConfiguration:c completionHandler:^(WKFindResult *r) {
        if (!r.matchFound) { [PW findCount:0 active:0]; return; }
        // WebKit doesn't report a count; count the visible text's matches ourselves
        [self->_web callAsyncJavaScript:@"const t = (document.body && document.body.innerText || '').toLowerCase(); const n = q.toLowerCase(); let c = 0, i = 0; while ((i = t.indexOf(n, i)) !== -1) { c++; i += n.length; } return c;"
                              arguments:@{@"q": q} inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id n, NSError *e) {
            [PW findCount:MAX(1, [n intValue]) active:-1];
        }];
    }];
}
- (void)stopFind { [_web evaluateJavaScript:@"window.getSelection().removeAllRanges()" completionHandler:nil]; }

- (void)source:(void (^)(NSString *))done {
    [_web evaluateJavaScript:@"document.documentElement.outerHTML" completionHandler:^(id r, NSError *e) { done([r isKindOfClass:NSString.class] ? r : @""); }];
}
- (void)runJS:(NSString *)code {   // test harness: evaluate an expression (awaited) and log the result
    [_web callAsyncJavaScript:[NSString stringWithFormat:@"const r = await (%@); return typeof r === 'object' ? JSON.stringify(r) : String(r);", code]
                    arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id r, NSError *e) {
        NSString *out = e ? [@"ERR " stringByAppendingString:(e.userInfo[@"WKJavaScriptExceptionMessage"] ?: e.localizedDescription)] : [r description];
        CtlOut([NSString stringWithFormat:@"js %@", out.length > 4000 ? [out substringToIndex:4000] : out]);
    }];
}
- (void)print {
    NSPrintOperation *op = [_web printOperationWithPrintInfo:NSPrintInfo.sharedPrintInfo];
    op.view.frame = self.bounds;
    [op runOperationModalForWindow:self.window delegate:nil didRunSelector:nil contextInfo:nil];
}

@end
#undef PW

#pragma mark - Element blocking (uBlock-style "block element")

// Rules are kept per site as CSS selectors and hidden with a style sheet as each page starts.
// Flint's own JavaScript world does the work, so pages can't see or tamper with it.
static NSString *const kCosmetic = @"cosmeticFilters";   // host → [selector]

static NSString *SiteKey(NSString *host) {
    host = host.lowercaseString ?: @"";
    return [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
}

static NSString *CosmeticScript(void) {
    return @"(()=>{if(!/^https?:$/.test(location.protocol))return;try{webkit.messageHandlers.flintCosmetic.postMessage({op:'get',host:location.hostname}).then(list=>{"
            "if(!list||!list.length)return;const s=document.createElement('style');s.id='flint-cosmetic';"
            "s.textContent=list.map(x=>x+'{display:none!important}').join('\\n');"
            "const put=()=>(document.head||document.documentElement).appendChild(s);document.documentElement?put():document.addEventListener('readystatechange',put,{once:true})})}catch(e){}})();";
}

static NSString *PickerScript(void) {
    return @"(()=>{"
    "if(window.__flintPicker)window.__flintPicker.stop();"
    "const doc=document,root=doc.documentElement,esc=CSS.escape;"
    "const host=doc.createElement('flint-picker');const sh=host.attachShadow({mode:'closed'});"
    "host.style.cssText='all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none';"
    "sh.innerHTML='<style>"
      ".box{position:fixed;pointer-events:none;background:rgba(140,150,255,.16);outline:2px solid rgba(140,150,255,.85);border-radius:3px;transition:all .05s}"
      ".bar{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);pointer-events:auto;display:flex;gap:8px;align-items:center;padding:9px 9px 9px 14px;border-radius:12px;"
        "background:#1c1c1f;color:#ececee;font:13px -apple-system,system-ui;box-shadow:0 12px 40px rgba(0,0,0,.45);border:1px solid #333;width:min(780px,calc(100vw - 32px));box-sizing:border-box}"
      ".t{font-weight:600;white-space:nowrap}.hint{color:#8b8b92;font-size:11.5px;white-space:nowrap}"
      ".sel{flex:1;min-width:120px;font:12px ui-monospace,Menlo,monospace;background:#26262a;color:#ececee;border:1px solid #3a3a3f;border-radius:8px;padding:6px 8px;outline:none}"
      "button{font:600 12.5px -apple-system,system-ui;border:0;border-radius:8px;padding:7px 12px;cursor:pointer;background:#2c2c30;color:#ececee}"
      "button.go{background:#ececee;color:#111}button:disabled{opacity:.4;cursor:default}"
    "</style><div class=box></div><div class=bar><span class=t>Block element</span><span class=hint>click to choose · ↑↓ wider or narrower · esc</span>"
      "<input class=sel spellcheck=false><span class=\"hint n\"></span><button class=cancel>Cancel</button><button class=go>Block</button></div>';"
    "root.appendChild(host);"
    "const box=sh.querySelector('.box'),input=sh.querySelector('.sel'),count=sh.querySelector('.n'),go=sh.querySelector('.go');"
    "let cur=null,locked=false,trail=[];"
    // a selector precise enough to match this element and as few others as possible
    "const sel=el=>{if(el.id&&!/\\d{3,}/.test(el.id)&&doc.querySelectorAll('#'+esc(el.id)).length===1)return'#'+esc(el.id);"
      "const parts=[];let e=el;"
      "while(e&&e.nodeType===1&&e!==doc.body&&e!==root&&parts.length<6){let p=e.tagName.toLowerCase();"
        "const cls=[...e.classList].filter(c=>c.length<40&&!/\\d{4,}/.test(c)).slice(0,3);if(cls.length)p+='.'+cls.map(esc).join('.');"
        "const par=e.parentElement;if(par){const same=[...par.children].filter(c=>c.tagName===e.tagName);"
          "if(same.filter(c=>cls.every(x=>c.classList.contains(x))).length>1)p+=':nth-of-type('+(same.indexOf(e)+1)+')'}"
        "parts.unshift(p);const s=parts.join(' > ');try{if(doc.querySelectorAll(s).length===1)return s}catch(x){}"
        "if(par&&par.id&&!/\\d{3,}/.test(par.id)){parts.unshift('#'+esc(par.id));return parts.join(' > ')}"
        "e=par}"
      "return parts.join(' > ')};"
    "const upd=()=>{let n=0;try{n=input.value.trim()?doc.querySelectorAll(input.value).length:0}catch(e){n=-1}"
      "count.textContent=n<0?'invalid':n===1?'1 match':n+' matches';go.disabled=n<=0};"
    "const show=el=>{if(!el||el===host)return;cur=el;const r=el.getBoundingClientRect();"
      "Object.assign(box.style,{left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'});input.value=sel(el);upd()};"
    "const inside=e=>e.composedPath&&e.composedPath().includes(host);"
    "const move=e=>{if(locked||inside(e))return;const el=doc.elementFromPoint(e.clientX,e.clientY);if(el&&el!==host){trail=[];show(el)}};"
    "const swallow=e=>{if(inside(e))return;e.preventDefault();e.stopPropagation();e.stopImmediatePropagation()};"
    "const click=e=>{if(inside(e))return;swallow(e);if(!locked){locked=true}else{locked=false;move(e)}};"
    "const key=e=>{if(e.key==='Escape'){e.preventDefault();stop();return}"
      "if(inside(e)&&e.key==='Enter'){e.preventDefault();block();return}"
      "if(inside(e))return;"
      "if(e.key==='ArrowUp'&&cur&&cur.parentElement&&cur.parentElement!==root&&cur.parentElement!==doc.body){e.preventDefault();trail.push(cur);locked=true;show(cur.parentElement)}"
      "else if(e.key==='ArrowDown'&&trail.length){e.preventDefault();show(trail.pop())}};"
    "const scroll=()=>{if(cur)show(cur)};"
    "const opts={capture:true};"
    "addEventListener('mousemove',move,opts);for(const t of['mousedown','mouseup','pointerdown','pointerup','auxclick','contextmenu'])addEventListener(t,swallow,opts);"
    "addEventListener('click',click,opts);addEventListener('keydown',key,opts);addEventListener('scroll',scroll,{capture:true,passive:true});"
    "input.addEventListener('input',()=>{try{const m=doc.querySelector(input.value);if(m){cur=m;const r=m.getBoundingClientRect();Object.assign(box.style,{left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'})}}catch(e){}upd()});"
    "const stop=()=>{removeEventListener('mousemove',move,opts);for(const t of['mousedown','mouseup','pointerdown','pointerup','auxclick','contextmenu'])removeEventListener(t,swallow,opts);"
      "removeEventListener('click',click,opts);removeEventListener('keydown',key,opts);removeEventListener('scroll',scroll,{capture:true});host.remove();window.__flintPicker=null};"
    "const block=()=>{const s=input.value.trim();if(!s||go.disabled)return;"
      "let st=doc.getElementById('flint-cosmetic');if(!st){st=doc.createElement('style');st.id='flint-cosmetic';(doc.head||root).appendChild(st)}"
      "st.textContent+='\\n'+s+'{display:none!important}';"
      "webkit.messageHandlers.flintCosmetic.postMessage({op:'add',host:location.hostname,selector:s});stop()};"
    "sh.querySelector('.cancel').onclick=stop;go.onclick=block;"
    "window.__flintPicker={stop};"
    "const start=window.__flintCtxEl;window.__flintCtxEl=null;if(start&&start.isConnected){locked=true;show(start)}"
    "})();";
}

// Cookie banners: find the consent manager's own "reject" button and press it, the way a person would.
// Known consent managers first (exact buttons), then a careful fallback: only inside an element that calls
// itself cookie/consent/privacy, only a button that says reject/decline (in several languages), never "accept".
static NSString *ConsentScript(void) {
    return @"(()=>{if(!/^https?:$/.test(location.protocol))return;"
    "const known=['#onetrust-reject-all-handler','#CybotCookiebotDialogBodyButtonDecline','#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll',"
      "'#didomi-notice-disagree-button','#truste-consent-required','button.sp_choice_type_REJECT_ALL',"
      "'.cmplz-btn.cmplz-deny','.cky-btn-reject','.osano-cm-denyAll','.iubenda-cs-reject-btn','.cm-btn-decline','[data-tid=\"banner-decline\"]','#axeptio_btn_dismiss',"
      "'#shopify-pc__banner__btn-decline','[data-cookiefirst-action=\"reject\"]','.moove-gdpr-infobar-reject-btn','#cn-refuse-cookie','#ccc-notify-reject',"
      "'.fc-cta-do-not-consent','#sp-cc-rejectall-link','#bnp_btn_reject','[data-cookiebanner=\"accept_only_essential_button\"]','button[action-type=\"DENY\"]',"
      "'[data-testid=\"uc-deny-all-button\"]','#uc-btn-deny-banner','.evidon-banner-declinebutton','#gdpr-banner-decline','.js-decline-all-cookies'];"
    "const no=/^\\s*(reject( all)?( cookies)?|decline( all)?( cookies)?|deny( all)?|refuse( all)?|disagree|i do not accept|do not consent|(use |allow )?(only )?(strictly )?(necessary|essential)( cookies)?( only)?|reject (all )?(optional|non-essential|additional) cookies|refuse non-essential cookies|decline optional cookies|continue without (accepting|agreeing)|alle ablehnen|ablehnen|nur (notwendige|erforderliche)( cookies)?|tout refuser|refuser( tout)?|continuer sans accepter|rechazar( todo| todas)?|rifiuta( tutto)?|weigeren|alles weigeren|alle afwijzen|rejeitar( tudo)?|recusar|odrzuć( wszystkie)?|avvisa alla|afvis alle|hylkää kaikki)\\s*$/i;"
    "const yes=/accept|agree|allow all|got it|akzept|accepter|aceptar|accetta/i;"
    "const Q='[id*=cookie i],[class*=cookie i],[id*=consent i],[class*=consent i],[id*=gdpr i],[class*=gdpr i],[aria-label*=cookie i],[aria-label*=consent i],[id^=cmp i],[class^=cmp i],[id*=privacy-banner i]';"
    "const B='button,[role=button],a[href=\"#\"],a:not([href]),input[type=button],input[type=submit]';"
    "const frameIsCmp=window!==top&&/privacy-mgmt|consent|cmp|sourcepoint|cookie/i.test(location.hostname+location.pathname);"
    "let done=false,tries=0,timer=0;"
    "const vis=el=>{const r=el.getBoundingClientRect();if(r.width<2||r.height<2)return false;const s=getComputedStyle(el);return s.visibility!=='hidden'&&s.display!=='none'&&+s.opacity>0.05};"
    "const press=el=>{done=true;try{el.click()}catch(e){}try{webkit.messageHandlers.flintCosmetic.postMessage({op:'consented',host:location.hostname,top:window===top})}catch(e){}};"
    "const roots=()=>{const out=[document];for(const h of document.querySelectorAll('#usercentrics-root,#usercentrics-cmp-ui,[id*=consent i],[class*=consent i]'))if(h.shadowRoot)out.push(h.shadowRoot);return out};"
    // only places that call themselves cookie/consent are searched, so ordinary pages cost next to nothing
    "const boxes=()=>{if(frameIsCmp)return[document];const out=new Set();for(const r of roots())for(const c of r.querySelectorAll(Q)){out.add(c);if(c.parentElement)out.add(c.parentElement)}return[...out].slice(0,30)};"
    "const scan=()=>{if(done||++tries>40)return stop();"
      "for(const r of roots())for(const s of known){let el;try{el=r.querySelector(s)}catch(e){}if(el&&vis(el)){press(el);return stop()}}"
      "for(const c of boxes())for(const el of c.querySelectorAll(B)){"
        "const t=(el.textContent||el.value||el.getAttribute('aria-label')||'').replace(/\\s+/g,' ').trim();"
        "if(!t||t.length>60||!no.test(t)||yes.test(t))continue;if(vis(el)){press(el);return stop()}}};"
    "let mo;const stop=()=>{if(mo)mo.disconnect();clearTimeout(timer)};"
    "const later=()=>{if(timer||done)return;timer=setTimeout(()=>{timer=0;scan()},400)};"
    "webkit.messageHandlers.flintCosmetic.postMessage({op:'consentOn',host:location.hostname}).then(on=>{if(!on)return;"
      "const go=()=>{scan();if(done)return;mo=new MutationObserver(later);mo.observe(document.documentElement,{childList:true,subtree:true});setTimeout(stop,20000)};"
      "document.readyState==='loading'?document.addEventListener('DOMContentLoaded',go,{once:true}):go()}).catch(()=>{})})();";
}

@interface VCosmetic : NSObject <WKScriptMessageHandlerWithReply>
+ (instancetype)shared;
@end

@implementation VCosmetic
+ (instancetype)shared { static VCosmetic *c; static dispatch_once_t once; dispatch_once(&once, ^{ c = [VCosmetic new]; }); return c; }
- (void)userContentController:(WKUserContentController *)u didReceiveScriptMessage:(WKScriptMessage *)m replyHandler:(void (^)(id, NSString *))reply {
    NSDictionary *b = [m.body isKindOfClass:NSDictionary.class] ? m.body : @{};
    NSString *site = SiteKey([b[@"host"] isKindOfClass:NSString.class] ? b[@"host"] : @"");
    if ([b[@"op"] isEqual:@"get"]) {
        BOOL off = ![Defaults() boolForKey:kBlock] || [[Defaults() arrayForKey:kAllowlist] containsObject:site] || [[Defaults() arrayForKey:kAllowlist] containsObject:[@"www." stringByAppendingString:site]];
        reply(off ? @[] : ([Defaults() dictionaryForKey:kCosmetic][site] ?: @[]), nil); return;
    }
    if ([b[@"op"] isEqual:@"consentOn"]) {
        NSArray *allow = [Defaults() arrayForKey:kAllowlist];
        reply(@([Defaults() boolForKey:kCookieReject] && ![allow containsObject:site] && ![allow containsObject:[@"www." stringByAppendingString:site]]), nil); return;
    }
    if ([b[@"op"] isEqual:@"consented"]) {   // shown once per site per launch; the banner usually never returns anyway
        static NSMutableSet *told; if (!told) told = [NSMutableSet set];
        NSString *top = SiteKey(m.webView.URL.host);
        if (top.length && ![told containsObject:top]) { [told addObject:top]; [WinOfWeb(m.webView) ?: gWin showToast:[NSString stringWithFormat:@"Declined cookies on %@", top]]; }
        reply(@YES, nil); return;
    }
    if ([b[@"op"] isEqual:@"add"] && m.frameInfo.isMainFrame) {
        NSString *sel = [b[@"selector"] isKindOfClass:NSString.class] ? Trim(b[@"selector"]) : @"";
        if (!site.length || !sel.length || sel.length > 600 || [sel rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"{}<"]].location != NSNotFound) { reply(@NO, nil); return; }
        NSMutableDictionary *all = [[Defaults() dictionaryForKey:kCosmetic] ?: @{} mutableCopy];
        NSMutableArray *list = [all[site] ?: @[] mutableCopy];
        if (![list containsObject:sel]) [list addObject:sel];
        all[site] = list; [Defaults() setObject:all forKey:kCosmetic];
        [WinOfWeb(m.webView) ?: gWin showToast:[NSString stringWithFormat:@"Element hidden on %@ · undo from the shield", site]];
        reply(@YES, nil); return;
    }
    reply(nil, @"unknown");
}
@end

// Scrollbars: when macOS shows classic always-on scroll bars (a mouse is connected, or "Show scroll bars: Always"),
// WebKit draws them as a white trough with a grey bar on every page, light or dark. Flint draws a thin rounded
// thumb on a clear track instead, in a grey that sits on either. It goes in first, so a site's own scroll bar styling
// still wins. With overlay scroll bars (trackpad only) macOS's own are already right and nothing is added.
static NSString *ScrollbarScript(void) {
    return @"(()=>{const css='::-webkit-scrollbar{width:11px;height:11px;background:transparent}'"
    "+'::-webkit-scrollbar-track,::-webkit-scrollbar-corner{background:transparent}'"
    "+'::-webkit-scrollbar-thumb{background-color:rgba(128,128,128,.38);border-radius:8px;border:3px solid transparent;background-clip:content-box;min-height:36px}'"
    "+'::-webkit-scrollbar-thumb:hover{background-color:rgba(128,128,128,.62)}'"
    "+'::-webkit-scrollbar-thumb:active{background-color:rgba(128,128,128,.75)}'"
    "+'::-webkit-scrollbar-button{display:none;width:0;height:0}';"
    "const put=()=>{if(document.getElementById('flint-scrollbar'))return;const st=document.createElement('style');st.id='flint-scrollbar';st.textContent=css;"
    "const r=document.documentElement;if(!r)return;r.insertBefore(st,r.firstChild)};"
    "put();document.addEventListener('DOMContentLoaded',put);})();";
}

static void FlintCosmeticInstall(WKUserContentController *ucc) {
    static NSHashTable *done; if (!done) done = [NSHashTable weakObjectsHashTable];
    if (!ucc || [done containsObject:ucc]) return;
    [done addObject:ucc];
    WKContentWorld *mine = [WKContentWorld worldWithName:@"flint"];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:CosmeticScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:mine]];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:ConsentScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:mine]];
    if (NSScroller.preferredScrollerStyle == NSScrollerStyleLegacy)
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:ScrollbarScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:mine]];
    [ucc addScriptMessageHandlerWithReply:VCosmetic.shared contentWorld:mine name:@"flintCosmetic"];
}

@implementation VWindow (Cosmetic)
- (void)blockElement:(id)s {
    VPage *p = self.current.web;
    if (!p || ![p.web.URL.scheme hasPrefix:@"http"]) { [self showToast:@"Open a web page to block an element on it"]; return; }
    [self.window makeFirstResponder:p.web];
    [p.web callAsyncJavaScript:PickerScript() arguments:@{} inFrame:nil inContentWorld:[WKContentWorld worldWithName:@"flint"] completionHandler:nil];
}
- (void)undoLastElement:(NSMenuItem *)i {
    NSString *site = i.representedObject;
    NSMutableDictionary *all = [[Defaults() dictionaryForKey:kCosmetic] ?: @{} mutableCopy];
    NSMutableArray *list = [all[site] ?: @[] mutableCopy];
    if (list.count) [list removeLastObject];
    if (list.count) all[site] = list; else [all removeObjectForKey:site];
    [Defaults() setObject:all forKey:kCosmetic];
    [self.current.web reload];
}
- (void)resetElements:(NSMenuItem *)i {
    NSMutableDictionary *all = [[Defaults() dictionaryForKey:kCosmetic] ?: @{} mutableCopy];
    [all removeObjectForKey:i.representedObject];
    [Defaults() setObject:all forKey:kCosmetic];
    [self.current.web reload];
    [self showToast:[NSString stringWithFormat:@"Hidden elements on %@ are back", i.representedObject]];
}
@end
#pragma mark - declarativeNetRequest: any extension's blocking rules, run by WebKit's own content blocker

// Chrome's declarativeNetRequest (the MV3 way ad blockers and privacy extensions block requests) is translated
// into WebKit content rule lists, the engine Safari's blockers use: the rules are compiled once and matched inside
// WebKit, with no per-request cost. This is general, not tied to one extension: static rulesets from the manifest,
// enabling/disabling rulesets, dynamic and session rules, and per-rule static disabling all work the same way for
// uBlock Origin Lite, AdGuard, Ghostery or anything else that uses the API.
//
// What maps over: block, allow, allowAllRequests and upgradeScheme; urlFilter (Adblock syntax) and regexFilter;
// request and initiator domains, resource types, first/third party, case sensitivity, and rule priority.
// What doesn't (WebKit can't do it): redirect and modifyHeaders actions, tab-specific and response-header rules —
// those rules are skipped, never applied wrongly.


// One-time probe: does this WebKit understand "load-context" (top frame vs child frame)? Unknown keys fail a whole list.
static BOOL gDNRLoadContext;

static NSString *DNREscapeChar(unichar c) {
    return strchr(".+?()[]{}\\$|^*/", (int)c) && c != '/' ? [NSString stringWithFormat:@"\\%C", c] : [NSString stringWithFormat:@"%C", c];
}

// Adblock-style urlFilter ("||ads.example.com^", "/banner/*.gif|") → WebKit regex. nil: can't be expressed.
static NSString *DNRURLFilterRegex(NSString *f, BOOL *domainAnchored) {
    NSMutableString *r = [NSMutableString string];
    NSUInteger i = 0, n = f.length;
    if (domainAnchored) *domainAnchored = NO;
    if ([f hasPrefix:@"||"]) { [r appendString:@"^[a-z][a-z0-9.+-]*://([^/?#]*\\.)?"]; i = 2; if (domainAnchored) *domainAnchored = YES; }
    else if ([f hasPrefix:@"|"]) { [r appendString:@"^"]; i = 1; }
    BOOL endAnchor = n > i && [f characterAtIndex:n - 1] == '|';
    if (endAnchor) n--;
    for (; i < n; i++) {
        unichar c = [f characterAtIndex:i];
        if (c > 126 || c < 32) return nil;   // WebKit's content rules are ASCII only
        if (c == '*') [r appendString:@".*"];
        else if (c == '^') [r appendString:(i == n - 1 && !endAnchor) ? @"([^a-zA-Z0-9_.%-].*)?$" : @"[^a-zA-Z0-9_.%-]"];
        else [r appendString:DNREscapeChar(c)];
    }
    if (endAnchor && ![r hasSuffix:@"$"]) [r appendString:@"$"];
    if (!r.length) [r appendString:@".*"];
    return r;
}

// RE2 (Chrome's regex flavour) → WebKit's content-rule subset, or nil with a reason when it uses something WebKit lacks
// (alternation, counted repeats, look-arounds, word boundaries, back-references).
static NSString *DNRRegex(NSString *src, NSString **why) {
    NSMutableString *r = [NSMutableString string];
    BOOL inClass = NO;
    NSUInteger n = src.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [src characterAtIndex:i];
        if (c > 126 || c < 32) { if (why) *why = @"non-ASCII"; return nil; }
        if (c == '\\') {
            if (i + 1 >= n) { if (why) *why = @"trailing escape"; return nil; }
            unichar d = [src characterAtIndex:++i];
            if (d == 'd') [r appendString:inClass ? @"0-9" : @"[0-9]"];
            else if (d == 'w') [r appendString:inClass ? @"a-zA-Z0-9_" : @"[a-zA-Z0-9_]"];
            else if (d == 'b' || d == 'B' || d == 's' || d == 'S' || d == 'D' || d == 'W' || isdigit(d) || d == 'p' || d == 'P') { if (why) *why = @"unsupported escape"; return nil; }
            else [r appendFormat:@"\\%C", d];
            continue;
        }
        if (inClass) { if (c == ']') inClass = NO; [r appendFormat:@"%C", c]; continue; }
        if (c == '[') { inClass = YES; [r appendString:@"["]; continue; }
        if (c == '|' || c == '{' || c == '}') { if (why) *why = @"alternation or counted repeat"; return nil; }
        if (c == '(' && i + 1 < n && [src characterAtIndex:i + 1] == '?') { if (why) *why = @"special group"; return nil; }
        if (c == '^' && i != 0) { if (why) *why = @"anchor in the middle"; return nil; }
        if (c == '$' && i != n - 1) { if (why) *why = @"anchor in the middle"; return nil; }
        if (c == '?' && i > 0 && strchr("*+?", (int)[src characterAtIndex:i - 1])) continue;   // lazy quantifier: same matches
        [r appendFormat:@"%C", c];
    }
    if (inClass) { if (why) *why = @"unclosed class"; return nil; }
    return r;
}

static NSString *DNRDomain(NSString *d) {
    if (![d isKindOfClass:NSString.class] || !d.length) return nil;
    d = d.lowercaseString;
    for (NSUInteger i = 0; i < d.length; i++) { unichar c = [d characterAtIndex:i]; if (!(isalnum(c) || c == '.' || c == '-' || c == '_')) return nil; }
    return d;
}
static NSString *DNRHostPrefix(NSString *domain) {   // matches the domain and its subdomains, at the start of an address
    NSMutableString *e = [NSMutableString string];
    for (NSUInteger i = 0; i < domain.length; i++) [e appendString:DNREscapeChar([domain characterAtIndex:i])];
    return [NSString stringWithFormat:@"^[a-z][a-z0-9.+-]*://([^/?#]*\\.)?%@", e];
}

// Chrome resource types → WebKit's. Frames are "document" (top or child frame where WebKit can tell them apart).
// Only types WebKit names exactly are mapped: WebKit's "raw" covers every fetch/XHR, so mapping pings, beacons,
// websockets or "other" onto it would turn a rule like "block third-party pings" into "block all third-party
// requests" (which stopped YouTube's video). Rules that only name such types are left out instead.
static void DNRAddTypes(NSArray *types, NSMutableSet *wk, BOOL *top, BOOL *child) {
    NSDictionary *m = @{@"stylesheet": @"style-sheet", @"script": @"script", @"image": @"image", @"font": @"font", @"media": @"media",
                        @"xmlhttprequest": @"raw"};
    for (NSString *t in types) {
        if (![t isKindOfClass:NSString.class]) continue;
        if ([t isEqualToString:@"main_frame"]) { [wk addObject:@"document"]; *top = YES; }
        else if ([t isEqualToString:@"sub_frame"]) { [wk addObject:@"document"]; *child = YES; }
        else if (m[t]) [wk addObject:m[t]];
    }
}
static NSArray *DNRAllTypes(void) { return @[@"main_frame", @"sub_frame", @"stylesheet", @"script", @"image", @"font", @"object", @"xmlhttprequest", @"ping", @"csp_report", @"media", @"websocket", @"webtransport", @"webbundle", @"other"]; }

typedef NS_ENUM(NSInteger, DNRKind) { DNRSkip, DNRBlock, DNRAllow };

// One Chrome rule → WebKit rules (often one; one per request domain when a rule names several).
// `kind` says whether they block (or upgrade) or exempt; `extra` collects exemptions a rule implies (excluded domains).
static NSArray<NSDictionary *> *DNRConvert(NSDictionary *rule, DNRKind *kind, NSMutableArray *extraAllows) {
    *kind = DNRSkip;
    NSDictionary *a = [rule[@"action"] isKindOfClass:NSDictionary.class] ? rule[@"action"] : nil;
    NSDictionary *c = [rule[@"condition"] isKindOfClass:NSDictionary.class] ? rule[@"condition"] : @{};
    NSString *type = a[@"type"];
    if (![type isKindOfClass:NSString.class]) return @[];
    if (c[@"tabIds"] || c[@"responseHeaders"] || c[@"excludedResponseHeaders"]) return @[];
    if ([c[@"requestMethods"] isKindOfClass:NSArray.class] && ![c[@"requestMethods"] containsObject:@"get"]) return @[];

    NSString *wkAction; BOOL allowAll = NO;
    if ([type isEqualToString:@"block"]) { wkAction = @"block"; *kind = DNRBlock; }
    else if ([type isEqualToString:@"upgradeScheme"]) { wkAction = @"make-https"; *kind = DNRBlock; }
    else if ([type isEqualToString:@"allow"]) { wkAction = @"ignore-previous-rules"; *kind = DNRAllow; }
    else if ([type isEqualToString:@"allowAllRequests"]) { wkAction = @"ignore-previous-rules"; *kind = DNRAllow; allowAll = YES; }
    else return @[];   // redirect, modifyHeaders: WebKit's blocker can't do these

    // where the request comes from
    NSMutableDictionary *base = [NSMutableDictionary dictionary];
    NSMutableArray *ifd = [NSMutableArray array], *unless = [NSMutableArray array];
    for (NSString *d in [c[@"initiatorDomains"] isKindOfClass:NSArray.class] ? c[@"initiatorDomains"] : ([c[@"domains"] isKindOfClass:NSArray.class] ? c[@"domains"] : @[])) { NSString *x = DNRDomain(d); if (x) [ifd addObject:[@"*" stringByAppendingString:x]]; }
    for (NSString *d in [c[@"excludedInitiatorDomains"] isKindOfClass:NSArray.class] ? c[@"excludedInitiatorDomains"] : ([c[@"excludedDomains"] isKindOfClass:NSArray.class] ? c[@"excludedDomains"] : @[])) { NSString *x = DNRDomain(d); if (x) [unless addObject:[@"*" stringByAppendingString:x]]; }
    if ([c[@"initiatorDomains"] isKindOfClass:NSArray.class] && [c[@"initiatorDomains"] count] && !ifd.count) { *kind = DNRSkip; return @[]; }
    if (!allowAll) { if (ifd.count) base[@"if-domain"] = ifd; else if (unless.count) base[@"unless-domain"] = unless; }

    // what kind of request
    NSMutableSet *wkTypes = [NSMutableSet set]; BOOL top = NO, child = NO;
    if ([c[@"resourceTypes"] isKindOfClass:NSArray.class]) DNRAddTypes(c[@"resourceTypes"], wkTypes, &top, &child);
    else {
        NSMutableArray *all = [DNRAllTypes() mutableCopy];
        if ([c[@"excludedResourceTypes"] isKindOfClass:NSArray.class]) [all removeObjectsInArray:c[@"excludedResourceTypes"]];
        else [all removeObject:@"main_frame"];   // Chrome's default: everything but the page itself
        DNRAddTypes(all, wkTypes, &top, &child);
    }
    if (!wkTypes.count) { *kind = DNRSkip; return @[]; }
    if ([wkTypes containsObject:@"document"] && !(top && child)) {
        if (gDNRLoadContext) base[@"load-context"] = @[top ? @"top-frame" : @"child-frame"];
        else if (!top) [wkTypes removeObject:@"document"];   // can't tell frames apart: never block whole pages by mistake
        if (!wkTypes.count) { *kind = DNRSkip; return @[]; }
    }
    if (!allowAll) base[@"resource-type"] = [wkTypes.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if ([c[@"domainType"] isEqual:@"firstParty"]) base[@"load-type"] = @[@"first-party"];
    else if ([c[@"domainType"] isEqual:@"thirdParty"]) base[@"load-type"] = @[@"third-party"];
    if ([c[@"isUrlFilterCaseSensitive"] boolValue]) base[@"url-filter-is-case-sensitive"] = @YES;

    // which addresses
    NSString *pattern = nil; BOOL domainAnchored = NO;
    if ([c[@"regexFilter"] isKindOfClass:NSString.class]) { pattern = DNRRegex(c[@"regexFilter"], NULL); if (!pattern) { *kind = DNRSkip; return @[]; } }
    else if ([c[@"urlFilter"] isKindOfClass:NSString.class]) { pattern = DNRURLFilterRegex(c[@"urlFilter"], &domainAnchored); if (!pattern) { *kind = DNRSkip; return @[]; } }
    NSMutableArray *domains = [NSMutableArray array];
    for (NSString *d in [c[@"requestDomains"] isKindOfClass:NSArray.class] ? c[@"requestDomains"] : @[]) { NSString *x = DNRDomain(d); if (x) [domains addObject:x]; }
    if ([c[@"requestDomains"] isKindOfClass:NSArray.class] && [c[@"requestDomains"] count] && !domains.count) { *kind = DNRSkip; return @[]; }

    NSMutableArray<NSString *> *filters = [NSMutableArray array];
    if (domains.count && !domainAnchored && ![pattern hasPrefix:@"^"]) {
        for (NSString *d in domains) [filters addObject:pattern ? [NSString stringWithFormat:@"%@[/:?#].*%@", DNRHostPrefix(d), [pattern hasPrefix:@".*"] ? [pattern substringFromIndex:2] : pattern]
                                                           : [NSString stringWithFormat:@"%@([/:?#].*)?$", DNRHostPrefix(d)]];
    } else [filters addObject:pattern ?: @".*"];

    NSMutableArray *out = [NSMutableArray array];
    if (allowAll) {   // the pages this matches, and everything they load, are exempt
        for (NSString *f in filters) [out addObject:@{@"trigger": @{@"url-filter": @".*", @"if-top-url": @[f]}, @"action": @{@"type": wkAction}}];
        return out;
    }
    for (NSString *f in filters) { NSMutableDictionary *t = [base mutableCopy]; t[@"url-filter"] = f; [out addObject:@{@"trigger": t, @"action": @{@"type": wkAction}}]; }
    // "except requests to these domains": an exemption scoped to this rule's other conditions
    if (*kind == DNRBlock && extraAllows) for (NSString *d in [c[@"excludedRequestDomains"] isKindOfClass:NSArray.class] ? c[@"excludedRequestDomains"] : @[]) {
        NSString *x = DNRDomain(d); if (!x) continue;
        NSMutableDictionary *t = [base mutableCopy]; t[@"url-filter"] = [NSString stringWithFormat:@"%@([/:?#].*)?$", DNRHostPrefix(x)];
        [extraAllows addObject:@{@"trigger": t, @"action": @{@"type": @"ignore-previous-rules"}}];
    }
    return out;
}

#pragma mark Per-extension state

@interface FDNRExt : NSObject
@property (copy) NSString *ident, *dir;
@property (strong) NSArray<NSDictionary *> *resources;           // manifest rule_resources: {id, enabled, path}
@property (strong) NSMutableOrderedSet<NSString *> *enabled;     // enabled static rulesets
@property (strong) NSMutableArray<NSDictionary *> *dynamicRules, *sessionRules;
@property (strong) NSMutableDictionary<NSString *, NSArray *> *disabledStatic;   // ruleset id → rule ids turned off
@property (strong) NSMutableArray *waiters;                      // replies waiting for the next compile to finish
@property BOOL compiling, again;
@property NSUInteger ruleCount, skipped;
@end
@implementation FDNRExt
@end

@interface FDNR : NSObject
+ (instancetype)shared;
- (void)loadExtension:(NSString *)ident dir:(NSString *)dir manifest:(NSDictionary *)m storeDir:(NSString *)storeDir;
- (void)op:(NSString *)op ext:(NSString *)ident args:(NSArray *)args reply:(void (^)(id result, NSString *error))reply;
- (void)forget:(NSString *)ident;
@end

@implementation FDNR {
    NSMutableDictionary<NSString *, FDNRExt *> *_exts;
    NSString *_storeDir;
}
+ (instancetype)shared {
    static FDNR *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [FDNR new]; d->_exts = [NSMutableDictionary dictionary]; if (!gExtRuleLists) gExtRuleLists = [NSMutableDictionary dictionary]; });
    return d;
}

- (NSString *)statePath:(FDNRExt *)x { return [_storeDir stringByAppendingPathComponent:[x.ident stringByAppendingString:@"-dnr.json"]]; }
- (void)saveState:(FDNRExt *)x {
    NSDictionary *s = @{@"enabled": x.enabled.array, @"dynamic": x.dynamicRules, @"disabledStatic": x.disabledStatic};
    [[NSJSONSerialization dataWithJSONObject:s options:0 error:nil] writeToFile:[self statePath:x] atomically:YES];
}

- (void)loadExtension:(NSString *)ident dir:(NSString *)dir manifest:(NSDictionary *)m storeDir:(NSString *)storeDir {
    _storeDir = storeDir;
    id dnr = m[@"declarative_net_request"];
    NSArray *res = [dnr isKindOfClass:NSDictionary.class] && [dnr[@"rule_resources"] isKindOfClass:NSArray.class] ? dnr[@"rule_resources"] : @[];
    NSArray *perms = [m[@"permissions"] isKindOfClass:NSArray.class] ? m[@"permissions"] : @[];
    if (!res.count && ![perms containsObject:@"declarativeNetRequest"] && ![perms containsObject:@"declarativeNetRequestWithHostAccess"]) return;
    static dispatch_once_t probe;
    dispatch_once(&probe, ^{   // learn once whether this WebKit knows "load-context"
        NSString *json = @"[{\"trigger\":{\"url-filter\":\"^flint-probe:\",\"resource-type\":[\"document\"],\"load-context\":[\"child-frame\"]},\"action\":{\"type\":\"block\"}}]";
        [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"flint-dnr-probe" encodedContentRuleList:json completionHandler:^(WKContentRuleList *l, NSError *e) { gDNRLoadContext = l != nil; }];
    });
    FDNRExt *x = [FDNRExt new];
    x.ident = ident; x.dir = dir; x.resources = res;
    x.waiters = [NSMutableArray array]; x.sessionRules = [NSMutableArray array];
    NSDictionary *saved = nil;
    NSData *d = [NSData dataWithContentsOfFile:[self statePath:x]];
    if (d) saved = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil];
    NSMutableOrderedSet *en = [NSMutableOrderedSet orderedSet];
    if ([saved[@"enabled"] isKindOfClass:NSArray.class]) [en addObjectsFromArray:saved[@"enabled"]];
    else for (NSDictionary *r in res) if ([r isKindOfClass:NSDictionary.class] && [r[@"enabled"] boolValue] && r[@"id"]) [en addObject:r[@"id"]];
    x.enabled = en;
    x.dynamicRules = [saved[@"dynamic"] isKindOfClass:NSArray.class] ? [saved[@"dynamic"] mutableCopy] : [NSMutableArray array];
    x.disabledStatic = [saved[@"disabledStatic"] isKindOfClass:NSDictionary.class] ? [saved[@"disabledStatic"] mutableCopy] : [NSMutableDictionary dictionary];
    _exts[ident] = x;
    // give the probe a moment, then bring the rules up (from WebKit's compiled cache when nothing changed)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self rebuild:x reply:nil]; });
}

- (void)forget:(NSString *)ident { [_exts removeObjectForKey:ident]; [gExtRuleLists removeObjectForKey:ident]; FlintApplyRules(); }

- (NSString *)fingerprint:(FDNRExt *)x {
    NSMutableString *fp = [NSMutableString stringWithFormat:@"v2|lc%d|", gDNRLoadContext];   // bump when the translation changes
    for (NSString *rid in x.enabled) {
        for (NSDictionary *r in x.resources) if ([r[@"id"] isEqual:rid]) {
            NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:[x.dir stringByAppendingPathComponent:r[@"path"] ?: @""] error:nil];
            [fp appendFormat:@"%@:%llu:%.0f|", rid, a.fileSize, a.fileModificationDate.timeIntervalSince1970];
        }
    }
    NSData *dyn = [NSJSONSerialization dataWithJSONObject:@[x.dynamicRules, x.sessionRules, x.disabledStatic] options:NSJSONWritingSortedKeys error:nil];
    unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(dyn.bytes, (CC_LONG)dyn.length, h);
    for (int i = 0; i < 8; i++) [fp appendFormat:@"%02x", h[i]];
    return fp;
}

// Gather every active rule, translate, and compile — or reuse WebKit's compiled copy when nothing changed.
- (void)rebuild:(FDNRExt *)x reply:(void (^)(void))done {
    if (done) [x.waiters addObject:[done copy]];
    if (x.compiling) { x.again = YES; return; }
    x.compiling = YES; x.again = NO;
    NSString *fp = [self fingerprint:x];
    NSString *fpKey = [@"dnr.fp." stringByAppendingString:x.ident], *idsKey = [@"dnr.lists." stringByAppendingString:x.ident];
    void (^finish)(NSArray *) = ^(NSArray *lists) {
        gExtRuleLists[x.ident] = lists ?: @[];
        FlintApplyRules();
        x.compiling = NO;
        NSArray *w = x.waiters.copy; [x.waiters removeAllObjects];
        for (void (^b)(void) in w) b();
        if (x.again) [self rebuild:x reply:nil];
    };
    NSArray *cachedIds = [Defaults() arrayForKey:idsKey];
    if ([[Defaults() stringForKey:fpKey] isEqualToString:fp] && cachedIds) {
        NSMutableArray *found = [NSMutableArray array];
        __block NSUInteger pending = cachedIds.count; __block BOOL missing = NO;
        if (!pending) { finish(@[]); return; }
        for (NSString *lid in cachedIds) [WKContentRuleListStore.defaultStore lookUpContentRuleListForIdentifier:lid completionHandler:^(WKContentRuleList *l, NSError *e) {
            if (l) [found addObject:l]; else missing = YES;
            if (--pending) return;
            if (!missing) { DLog(@"extension rules: %@ from cache (%lu lists)", x.ident, (unsigned long)found.count); finish(found); }
            else { [Defaults() removeObjectForKey:fpKey]; x.compiling = NO; [self rebuild:x reply:nil]; }
        }];
        return;
    }
    NSArray *enabled = x.enabled.array, *resources = x.resources, *dynamic = x.dynamicRules.copy, *session = x.sessionRules.copy;
    NSDictionary *disabled = x.disabledStatic.copy; NSString *dir = x.dir;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDate *t0 = NSDate.date;
        NSMutableArray *rules = [NSMutableArray array];
        for (NSString *rid in enabled) for (NSDictionary *r in resources) if ([r[@"id"] isEqual:rid] && [r[@"path"] isKindOfClass:NSString.class]) {
            NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:r[@"path"]]];
            NSArray *a = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            NSSet *off = [NSSet setWithArray:[disabled[rid] isKindOfClass:NSArray.class] ? disabled[rid] : @[]];
            if ([a isKindOfClass:NSArray.class]) for (NSDictionary *rule in a) if ([rule isKindOfClass:NSDictionary.class] && ![off containsObject:rule[@"id"] ?: @-1]) [rules addObject:rule];
        }
        [rules addObjectsFromArray:dynamic]; [rules addObjectsFromArray:session];
        // translate; blocks and exemptions kept apart, each with its priority
        NSMutableArray *blocks = [NSMutableArray array], *allows = [NSMutableArray array];
        NSUInteger skipped = 0;
        for (NSDictionary *rule in rules) {
            DNRKind k; NSMutableArray *extra = [NSMutableArray array];
            NSArray *wk = DNRConvert(rule, &k, extra);
            if (k == DNRSkip || !wk.count) { skipped++; continue; }
            NSInteger pr = [rule[@"priority"] isKindOfClass:NSNumber.class] ? [rule[@"priority"] integerValue] : 1;
            for (NSDictionary *w in wk) [(k == DNRAllow ? allows : blocks) addObject:@[@(pr), w]];
            for (NSDictionary *w in extra) [allows addObject:@[@(pr), w]];
        }
        NSComparator byPriority = ^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; };
        [blocks sortWithOptions:NSSortStable usingComparator:byPriority];
        [allows sortWithOptions:NSSortStable usingComparator:byPriority];
        // WebKit's exemptions only reach rules earlier in the same list, so every list carries all exemptions,
        // interleaved by priority (a higher-priority block still wins over a lower-priority allow, as in Chrome)
        NSUInteger per = MAX(10000, MIN(60000, 140000 - MIN(allows.count, 80000)));
        NSMutableArray<NSArray *> *chunks = [NSMutableArray array];
        for (NSUInteger i = 0; i < blocks.count || (i == 0 && allows.count); i += per) {
            NSArray *slice = blocks.count ? [blocks subarrayWithRange:NSMakeRange(i, MIN(per, blocks.count - i))] : @[];
            NSMutableArray *merged = [NSMutableArray arrayWithCapacity:slice.count + allows.count];
            NSUInteger bi = 0, ai = 0;
            while (bi < slice.count || ai < allows.count) {
                BOOL takeBlock = ai >= allows.count || (bi < slice.count && [slice[bi][0] integerValue] <= [allows[ai][0] integerValue]);
                [merged addObject:takeBlock ? slice[bi++][1] : allows[ai++][1]];
            }
            [chunks addObject:merged];
            if (!blocks.count) break;
        }
        NSUInteger total = blocks.count + allows.count;
        dispatch_async(dispatch_get_main_queue(), ^{
            x.ruleCount = total; x.skipped = skipped;
            if (!chunks.count) { [Defaults() setObject:fp forKey:fpKey]; [Defaults() setObject:@[] forKey:idsKey]; finish(@[]); return; }
            NSMutableArray *lists = [NSMutableArray array], *ids = [NSMutableArray array];
            __block NSUInteger pending = chunks.count;
            for (NSUInteger k = 0; k < chunks.count; k++) {
                [self compile:chunks[k] ident:[NSString stringWithFormat:@"flint-dnr-%@-%lu", x.ident, (unsigned long)k] into:lists ids:ids done:^{
                    if (--pending) return;
                    [Defaults() setObject:fp forKey:fpKey]; [Defaults() setObject:ids forKey:idsKey];
                    DLog(@"extension rules: %@ → %lu WebKit rules in %lu lists (%lu Chrome rules not expressible), %.1fs", x.ident, (unsigned long)total, (unsigned long)lists.count, (unsigned long)skipped, -t0.timeIntervalSinceNow);
                    finish(lists);
                }];
            }
        });
    });
}

// Compile one list; if WebKit rejects it, split it until the rule it can't take is set aside (the rest still work).
- (void)compile:(NSArray *)rules ident:(NSString *)ident into:(NSMutableArray *)lists ids:(NSMutableArray *)ids done:(void (^)(void))done {
    NSData *d = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:ident encodedContentRuleList:json completionHandler:^(WKContentRuleList *l, NSError *err) {
        if (l) { [lists addObject:l]; [ids addObject:ident]; done(); return; }
        if (rules.count <= 1) { DLog(@"extension rule set aside: %@", err.localizedDescription); done(); return; }
        // keep exemptions with both halves (they must follow the rules they exempt)
        NSMutableArray *a = [NSMutableArray array], *b = [NSMutableArray array];
        NSUInteger half = rules.count / 2, blocksSeen = 0, blockTotal = 0;
        for (NSDictionary *r in rules) if (![r[@"action"][@"type"] isEqual:@"ignore-previous-rules"]) blockTotal++;
        for (NSDictionary *r in rules) {
            BOOL allow = [r[@"action"][@"type"] isEqual:@"ignore-previous-rules"];
            if (allow && blockTotal > 1) { [a addObject:r]; [b addObject:r]; continue; }
            if (blockTotal > 1) { [(blocksSeen++ < blockTotal / 2 ? a : b) addObject:r]; }
            else [(a.count < half ? a : b) addObject:r];
        }
        if (!a.count || !b.count || a.count == rules.count) { DLog(@"extension rule list %@ failed: %@", ident, err.localizedDescription); done(); return; }
        __block int left = 2;
        void (^both)(void) = ^{ if (--left == 0) done(); };
        [self compile:a ident:[ident stringByAppendingString:@"a"] into:lists ids:ids done:both];
        [self compile:b ident:[ident stringByAppendingString:@"b"] into:lists ids:ids done:both];
    }];
}

#pragma mark chrome.declarativeNetRequest calls

static NSArray *DNRFilterRules(NSArray *rules, id ids) {
    if (![ids isKindOfClass:NSArray.class]) return rules;
    NSSet *want = [NSSet setWithArray:ids];
    NSMutableArray *out = [NSMutableArray array]; for (NSDictionary *r in rules) if ([want containsObject:r[@"id"] ?: @-1]) [out addObject:r];
    return out;
}
// add/remove by id, as Chrome does: removals first, then additions (duplicate ids are an error)
static NSString *DNRUpdate(NSMutableArray *rules, NSDictionary *opts, NSUInteger limit) {
    NSArray *remove = [opts[@"removeRuleIds"] isKindOfClass:NSArray.class] ? opts[@"removeRuleIds"] : @[];
    NSArray *add = [opts[@"addRules"] isKindOfClass:NSArray.class] ? opts[@"addRules"] : @[];
    NSMutableArray *next = [NSMutableArray array];
    NSSet *gone = [NSSet setWithArray:remove];
    for (NSDictionary *r in rules) if (![gone containsObject:r[@"id"] ?: @-1]) [next addObject:r];
    NSMutableSet *seen = [NSMutableSet set]; for (NSDictionary *r in next) if (r[@"id"]) [seen addObject:r[@"id"]];
    for (NSDictionary *r in add) {
        if (![r isKindOfClass:NSDictionary.class] || ![r[@"id"] isKindOfClass:NSNumber.class]) return @"Rule with an invalid id";
        if ([seen containsObject:r[@"id"]]) return [NSString stringWithFormat:@"Rule with id %@ does not have a unique ID.", r[@"id"]];
        [seen addObject:r[@"id"]]; [next addObject:r];
    }
    if (next.count > limit) return @"Rule count exceeds the limit";
    [rules setArray:next];
    return nil;
}

- (void)op:(NSString *)op ext:(NSString *)ident args:(NSArray *)args reply:(void (^)(id, NSString *))reply {
    FDNRExt *x = _exts[ident];
    id a0 = args.count ? args[0] : nil; if (a0 == NSNull.null) a0 = nil;
    NSDictionary *o = [a0 isKindOfClass:NSDictionary.class] ? a0 : @{};
    if ([op isEqualToString:@"dnr.isRegexSupported"]) {
        NSString *why = nil; BOOL okRx = [o[@"regex"] isKindOfClass:NSString.class] && DNRRegex(o[@"regex"], &why) != nil;
        reply(okRx ? @{@"isSupported": @YES} : @{@"isSupported": @NO, @"reason": @"syntaxError"}, nil); return;
    }
    if ([op isEqualToString:@"dnr.getMatchedRules"]) { reply(@{@"rulesMatchedInfo": @[]}, nil); return; }
    if ([op isEqualToString:@"dnr.testMatchOutcome"]) { reply(@{@"matchedRules": @[]}, nil); return; }
    if ([op isEqualToString:@"dnr.setExtensionActionOptions"]) { reply(NSNull.null, nil); return; }
    if (!x) {   // no rules declared: answer as an empty engine
        if ([op hasPrefix:@"dnr.get"]) reply(@[], nil); else if ([op isEqualToString:@"dnr.getAvailableStaticRuleCount"]) reply(@300000, nil); else reply(NSNull.null, nil);
        return;
    }
    void (^saveAndApply)(void) = ^{ [self saveState:x]; [self rebuild:x reply:^{ reply(NSNull.null, nil); }]; };
    if ([op isEqualToString:@"dnr.getEnabledRulesets"]) reply(x.enabled.array, nil);
    else if ([op isEqualToString:@"dnr.updateEnabledRulesets"]) {
        NSMutableSet *known = [NSMutableSet set]; for (NSDictionary *r in x.resources) if (r[@"id"]) [known addObject:r[@"id"]];
        for (NSString *rid in [o[@"enableRulesetIds"] isKindOfClass:NSArray.class] ? o[@"enableRulesetIds"] : @[]) if (![known containsObject:rid]) { reply(nil, [NSString stringWithFormat:@"Invalid ruleset id: %@.", rid]); return; }
        for (NSString *rid in [o[@"disableRulesetIds"] isKindOfClass:NSArray.class] ? o[@"disableRulesetIds"] : @[]) [x.enabled removeObject:rid];
        for (NSString *rid in [o[@"enableRulesetIds"] isKindOfClass:NSArray.class] ? o[@"enableRulesetIds"] : @[]) [x.enabled addObject:rid];
        saveAndApply();
    }
    else if ([op isEqualToString:@"dnr.getDynamicRules"]) reply(DNRFilterRules(x.dynamicRules, o[@"ruleIds"]), nil);
    else if ([op isEqualToString:@"dnr.getSessionRules"]) reply(DNRFilterRules(x.sessionRules, o[@"ruleIds"]), nil);
    else if ([op isEqualToString:@"dnr.updateDynamicRules"] || [op isEqualToString:@"dnr.updateSessionRules"]) {
        BOOL dyn = [op isEqualToString:@"dnr.updateDynamicRules"];
        NSString *err = DNRUpdate(dyn ? x.dynamicRules : x.sessionRules, o, dyn ? 30000 : 5000);
        if (err) { reply(nil, err); return; }
        if (dyn) saveAndApply(); else [self rebuild:x reply:^{ reply(NSNull.null, nil); }];
    }
    else if ([op isEqualToString:@"dnr.updateStaticRules"]) {
        NSString *rid = o[@"rulesetId"]; if (![rid isKindOfClass:NSString.class]) { reply(nil, @"Missing rulesetId"); return; }
        NSMutableSet *off = [NSMutableSet setWithArray:[x.disabledStatic[rid] isKindOfClass:NSArray.class] ? x.disabledStatic[rid] : @[]];
        [off addObjectsFromArray:[o[@"disableRuleIds"] isKindOfClass:NSArray.class] ? o[@"disableRuleIds"] : @[]];
        for (id i in [o[@"enableRuleIds"] isKindOfClass:NSArray.class] ? o[@"enableRuleIds"] : @[]) [off removeObject:i];
        x.disabledStatic[rid] = off.allObjects;
        saveAndApply();
    }
    else if ([op isEqualToString:@"dnr.getDisabledRuleIds"]) { NSString *rid = o[@"rulesetId"]; reply([rid isKindOfClass:NSString.class] && [x.disabledStatic[rid] isKindOfClass:NSArray.class] ? x.disabledStatic[rid] : @[], nil); }
    else if ([op isEqualToString:@"dnr.getAvailableStaticRuleCount"]) reply(@(MAX(0, 330000 - (NSInteger)x.ruleCount)), nil);
    else reply(nil, [@"Flint doesn't support " stringByAppendingString:op]);
}
@end
#pragma mark - Extensions: Flint's own Chrome-extension layer on WebKit
// Unpacked Chrome extensions live in ~/Library/Application Support/Flint/Extensions/<name>/.
// Content scripts run in a WebKit content world per extension (Chrome's "isolated world"),
// extension pages are served from chrome-extension://<id>/ by FExtHost, the background script
// runs in a hidden page, and chrome.* calls (ext-shim.js) come here through flintExt.

@interface FExt : NSObject
@property (copy) NSString *ident, *dir, *name;
@property (strong) NSDictionary *manifest, *messages;
@property (strong) WKContentWorld *world;
@property (strong) WKWebView *background;
@property (strong) NSWindow *bgWindow;
@property (strong) NSMutableDictionary *store;   // area -> {key: value}
@property BOOL bgReady;
@property (strong) NSMutableArray *bgQueue;     // calls waiting for the background page
@end
@implementation FExt
@end

@interface FPort : NSObject
@property (copy) NSString *ident;
@property (weak) WKWebView *aView, *bView;
@property (strong) WKContentWorld *aWorld, *bWorld;
@property (strong) WKFrameInfo *aFrame;
@end
@implementation FPort
@end

static NSString *ExtRoot(void) {
    NSString *d = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                    stringByAppendingPathComponent:@"Flint"] stringByAppendingPathComponent:@"Extensions"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

// Chrome's extension ID: the first 128 bits of SHA-256 of the public key, as letters a–p.
static NSString *ExtIDFromKey(NSString *b64) {
    NSData *key = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!key.length) return nil;
    unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(key.bytes, (CC_LONG)key.length, h);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%c%c", 'a' + (h[i] >> 4), 'a' + (h[i] & 15)];
    return s;
}

static id JSONFile(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path]; if (!d) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil];
    if (o) return o;
    // manifests sometimes carry comments or a BOM
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    s = [s stringByReplacingOccurrencesOfString:@"﻿" withString:@""];
    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"^\\s*//.*$" options:NSRegularExpressionAnchorsMatchLines error:nil];
    s = [rx stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    return [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:nil];
}

// the page world has no shim, so MAIN-world content scripts get their own copy of the match test
static NSString *MatchJS(void) {
    return @"const __flintMatch = (patterns, url) => (patterns || []).some(p => { if (p === '<all_urls>') return /^(https?|file|ftp|wss?):/.test(url);"
            "const m = /^(\\*|https?|file|ftp|wss?):\\/\\/([^/]*)(\\/.*)$/.exec(p); if (!m) return false; const esc = s => s.replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&');"
            "const scheme = m[1] === '*' ? '(https?|wss?)' : esc(m[1]); let host = m[2]; host = host === '*' ? '[^/]*' : host.startsWith('*.') ? '([^/]*\\\\.)?' + esc(host.slice(2)) : esc(host);"
            "const path = esc(m[3]).replace(/\\\\\\*/g, '.*').replace(/\\*/g, '.*'); return new RegExp('^' + scheme + '://' + host + '(:\\\\d+)?' + path + '$').test(url); });\n";
}

static NSString *MIMEFor(NSString *ext) {
    NSDictionary *m = @{@"html": @"text/html", @"htm": @"text/html", @"js": @"text/javascript", @"mjs": @"text/javascript", @"css": @"text/css",
                        @"json": @"application/json", @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"gif": @"image/gif",
                        @"svg": @"image/svg+xml", @"webp": @"image/webp", @"ico": @"image/x-icon", @"woff": @"font/woff", @"woff2": @"font/woff2",
                        @"ttf": @"font/ttf", @"otf": @"font/otf", @"wasm": @"application/wasm", @"txt": @"text/plain", @"map": @"application/json"};
    return m[ext.lowercaseString] ?: @"application/octet-stream";
}

static NSInteger TabID(VTab *t) {
    static char key; static NSInteger next = 1;
    NSNumber *n = objc_getAssociatedObject(t, &key);
    if (!n) { n = @(next++); objc_setAssociatedObject(t, &key, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return n.integerValue;
}
// Extensions see normal windows only; private windows are invisible to them, as in Chrome by default.
static VTab *TabForID(NSInteger i) { for (VTab *t in AllTabs(NO)) if (TabID(t) == i) return t; return nil; }
static VTab *TabForView(WKWebView *w) { for (VTab *t in AllTabs(NO)) if (t.web.web == w) return t; return nil; }
static NSInteger WinID(VWindow *w) {
    static NSInteger next = 1;
    NSNumber *n = objc_getAssociatedObject(w, "flintWinId");
    if (!n && w) { n = @(next++); objc_setAssociatedObject(w, "flintWinId", n, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return n.integerValue;
}
static VWindow *NormalWin(void) {
    if (gWin && !gWin.isPrivate) return gWin;
    for (VWindow *w in gWindows.reverseObjectEnumerator) if (!w.isPrivate) return w;
    return gWin;
}
static NSDictionary *TabInfo(VTab *t) {
    if (!t) return nil;
    VWindow *o = t.owner ?: gWin;
    return @{@"id": @(TabID(t)), @"index": @([o.tabs indexOfObject:t]), @"windowId": @(WinID(o)), @"active": @(t == o.current), @"highlighted": @(t == o.current),
             @"pinned": @(t.pinned), @"url": t.url ?: @"", @"title": t.title ?: @"", @"status": t.loading ? @"loading" : @"complete",
             @"incognito": @NO, @"audible": @NO, @"discarded": @(t.web == nil), @"autoDiscardable": @YES, @"groupId": @-1};
}

// Frames: Chrome gives every frame a number (0 = the page). WebKit's frames carry an id of their own; Flint
// remembers each frame that has talked to an extension, so later calls (executeScript, insertCSS, sendMessage
// with frameIds) can reach that exact frame.
static NSMapTable<WKWebView *, NSMutableDictionary<NSNumber *, WKFrameInfo *> *> *gFrames;
static NSNumber *FrameIDFor(WKFrameInfo *f) {
    if (!f || f.isMainFrame) return @0;
    @try { id h = [f valueForKey:@"_handle"]; id n = [h valueForKey:@"frameID"]; if ([n isKindOfClass:NSNumber.class] && [n unsignedLongLongValue]) return n; } @catch (NSException *x) {}
    return @1;
}
static void RememberFrame(WKWebView *v, WKFrameInfo *f) {
    if (!v || !f || f.isMainFrame) return;
    if (!gFrames) gFrames = [NSMapTable weakToStrongObjectsMapTable];
    NSMutableDictionary *d = [gFrames objectForKey:v]; if (!d) { d = [NSMutableDictionary dictionary]; [gFrames setObject:d forKey:v]; }
    if (d.count > 200) [d removeAllObjects];
    d[FrameIDFor(f)] = f;
}
// The frames a call targets: given ids, all frames, or the page.
static NSArray *TargetFrames(WKWebView *v, NSDictionary *target) {
    NSMutableArray *out = [NSMutableArray array];   // each: @[frameId, WKFrameInfo or NSNull (the page)]
    NSDictionary *known = [gFrames objectForKey:v] ?: @{};
    if ([target[@"frameIds"] isKindOfClass:NSArray.class]) {
        for (NSNumber *n in target[@"frameIds"]) { if (n.longLongValue == 0) [out addObject:@[@0, NSNull.null]]; else if (known[n]) [out addObject:@[n, known[n]]]; }
    } else {
        [out addObject:@[@0, NSNull.null]];
        if ([target[@"allFrames"] boolValue]) for (NSNumber *n in known) [out addObject:@[n, known[n]]];
    }
    return out;
}

// logs message types only, never contents (they can carry keys); on only while developing, when an "extdebug" file sits beside Flint.app
static BOOL gExtDebug = NO;
__attribute__((constructor)) static void FlintExtDebugInit(void) { gExtDebug = [NSBundle.mainBundle pathForResource:@"extdebug" ofType:nil] != nil; }

@interface FExtHost () <WKNavigationDelegate>
@end

@implementation FExtHost {
    NSMutableDictionary<NSString *, FExt *> *_exts, *_disabled;
    NSMutableDictionary<NSString *, FPort *> *_ports;
    NSMutableDictionary<NSString *, NSMutableArray<NSMutableDictionary *> *> *_menus;     // extension → its context-menu items, in order
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *_regScripts;       // extension → scripts it registered at run time
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *_userScripts;      // extension → chrome.userScripts entries
    NSHashTable<WKUserScript *> *_dynScripts;   // the WebKit scripts made from those (swapped out when they change)
    WKUserContentController *_ucc;
    BOOL _installed;
    NSString *_shim;
    NSPopover *_popover;
}

+ (instancetype)shared { static FExtHost *h; static dispatch_once_t o; dispatch_once(&o, ^{ h = [FExtHost new]; [h load]; }); return h; }
- (NSArray *)extensions { return [_exts.allValues sortedArrayUsingComparator:^NSComparisonResult(FExt *a, FExt *b) { return [a.name compare:b.name]; }]; }

- (void)load {
    _exts = [NSMutableDictionary dictionary];
    _disabled = [NSMutableDictionary dictionary];
    _ports = [NSMutableDictionary dictionary];
    _menus = [NSMutableDictionary dictionary];
    _regScripts = [NSMutableDictionary dictionary];
    _userScripts = [NSMutableDictionary dictionary];
    _dynScripts = [NSHashTable weakObjectsHashTable];
    _shim = [NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"ext-shim" ofType:@"js"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *root = ExtRoot();
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir = [root stringByAppendingPathComponent:n];
        NSDictionary *m = JSONFile([dir stringByAppendingPathComponent:@"manifest.json"]);
        if (![m isKindOfClass:NSDictionary.class]) continue;
        FExt *e = [FExt new];
        e.dir = dir; e.manifest = m;
        e.ident = ([m[@"key"] isKindOfClass:NSString.class] ? ExtIDFromKey(m[@"key"]) : nil) ?: n.lowercaseString;
        NSString *loc = [m[@"default_locale"] isKindOfClass:NSString.class] ? m[@"default_locale"] : @"en";
        NSDictionary *msgs = JSONFile([NSString stringWithFormat:@"%@/_locales/%@/messages.json", dir, loc]) ?: JSONFile([dir stringByAppendingPathComponent:@"_locales/en/messages.json"]) ?: @{};
        NSMutableDictionary *lower = [NSMutableDictionary dictionary];
        for (NSString *k in msgs) lower[k.lowercaseString] = msgs[k];
        lower[@"@@extension_id"] = @{@"message": e.ident};
        e.messages = lower;
        e.name = [self i18n:m[@"name"] ext:e] ?: n;
        e.world = [WKContentWorld worldWithName:[@"flint-ext-" stringByAppendingString:e.ident]];
        e.store = [NSMutableDictionary dictionary];
        for (NSString *area in @[@"local", @"sync"]) e.store[area] = JSONFile([self storePath:e area:area]) ?: [NSMutableDictionary dictionary];
        e.store[@"session"] = [NSMutableDictionary dictionary];
        e.store[@"managed"] = [NSMutableDictionary dictionary];
        e.bgQueue = [NSMutableArray array];
        if ([[Defaults() arrayForKey:kExtDisabled] containsObject:e.ident]) { _disabled[e.ident] = e; continue; }
        _exts[e.ident] = e;
        DLog(@"extension %@ (%@) from %@", e.name, e.ident, n);
        // scripts it registered last time (persistAcrossSessions) and its network rules
        NSArray *reg = JSONFile([self storePath:e area:@"scripts"]);
        _regScripts[e.ident] = [reg isKindOfClass:NSArray.class] ? [reg mutableCopy] : [NSMutableArray array];
        NSArray *us = JSONFile([self storePath:e area:@"userscripts"]);
        _userScripts[e.ident] = [us isKindOfClass:NSArray.class] ? [us mutableCopy] : [NSMutableArray array];
        [FDNR.shared loadExtension:e.ident dir:e.dir manifest:m storeDir:[self storePath:e area:@"x"].stringByDeletingLastPathComponent];
    }
}

- (NSString *)i18n:(NSString *)s ext:(FExt *)e {
    if (![s isKindOfClass:NSString.class]) return nil;
    if ([s hasPrefix:@"__MSG_"] && [s hasSuffix:@"__"]) {
        NSString *k = [[s substringWithRange:NSMakeRange(6, s.length - 8)] lowercaseString];
        NSString *v = e.messages[k][@"message"]; if (v.length) return v;
    }
    return s;
}

- (NSString *)storePath:(FExt *)e area:(NSString *)area {
    NSString *d = [ExtRoot().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Extension Storage"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return [d stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.json", e.ident, area]];
}

- (NSString *)configJSON:(NSString *)mode ext:(FExt *)only {
    NSMutableDictionary *exts = [NSMutableDictionary dictionary];
    NSMutableDictionary *external = [NSMutableDictionary dictionary];
    for (FExt *e in _exts.allValues) {
        if (only && e != only) continue;
        exts[e.ident] = @{@"manifest": e.manifest, @"messages": e.messages};
        for (NSString *pat in e.manifest[@"externally_connectable"][@"matches"] ?: @[]) {
            if (![pat isKindOfClass:NSString.class]) continue;
            NSString *origin = [pat componentsSeparatedByString:@"/*"].firstObject;   // https://account.proton.me/* → https://account.proton.me
            if ([origin containsString:@"*"]) continue;
            NSMutableArray *ids = external[origin] ?: [NSMutableArray array]; [ids addObject:e.ident]; external[origin] = ids;
        }
    }
    NSDictionary *cfg = @{@"mode": mode, @"ext": only ? only.ident : [NSNull null], @"exts": exts, @"external": external, @"debug": @(gExtDebug)};
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil] encoding:NSUTF8StringEncoding];
}

- (NSString *)shimFor:(NSString *)mode ext:(FExt *)e { return [_shim stringByReplacingOccurrencesOfString:@"__FLINT_CFG__" withString:[self configJSON:mode ext:e]]; }

// Page-world scripts from extensions assume Chrome's platform: requestIdleCallback and Trusted Types.
// WebKit (on this macOS) has neither, so they get minimal stand-ins — only on pages those scripts run on.
static NSString *PageWorldPolyfills(void) {
    return @"(()=>{const w=window;"
    "if(!w.requestIdleCallback){w.requestIdleCallback=(c,o)=>{const s=Date.now();return setTimeout(()=>c({didTimeout:false,timeRemaining:()=>Math.max(0,50-(Date.now()-s))}),1)};w.cancelIdleCallback=i=>clearTimeout(i)}"
    "if(!w.trustedTypes){const mk=n=>{const C=class{constructor(v){this._v=String(v)}toString(){return this._v}toJSON(){return this._v}};Object.defineProperty(C,'name',{value:n});return C};"
    "const H=mk('TrustedHTML'),S=mk('TrustedScript'),U=mk('TrustedScriptURL');w.TrustedHTML=H;w.TrustedScript=S;w.TrustedScriptURL=U;"
    "const pol=(n,r)=>{r=r||{};const f=(k,C)=>(v,...a)=>{if(!r[k])throw new TypeError('Policy '+n+' has no '+k);return new C(r[k](v,...a))};"
    "return{name:n,createHTML:f('createHTML',H),createScript:f('createScript',S),createScriptURL:f('createScriptURL',U)}};"
    "w.trustedTypes={createPolicy:pol,isHTML:v=>v instanceof H,isScript:v=>v instanceof S,isScriptURL:v=>v instanceof U,emptyHTML:new H(''),emptyScript:new S(''),"
    "getAttributeType:()=>null,getPropertyType:()=>null,defaultPolicy:null}}})();\n";
}

// Chrome match patterns → WebKit's own per-site user scripts (the same mechanism Safari's extensions use).
static NSArray<NSString *> *ChromePatterns(id list) {
    NSMutableArray *out = [NSMutableArray array];
    for (id p in [list isKindOfClass:NSArray.class] ? list : @[]) {
        if (![p isKindOfClass:NSString.class]) continue;
        if ([p isEqualToString:@"<all_urls>"]) { [out addObject:@"*://*/*"]; [out addObject:@"file:///*"]; }
        else [out addObject:p];
    }
    return out;
}
static WKUserScript *MatchedScript(NSString *src, WKUserScriptInjectionTime when, BOOL mainOnly, NSArray *inc, NSArray *exc, WKContentWorld *world) {
    SEL sel = NSSelectorFromString(@"_initWithSource:injectionTime:forMainFrameOnly:includeMatchPatternStrings:excludeMatchPatternStrings:associatedURL:contentWorld:deferRunningUntilNotification:");
    if (!inc.count || ![WKUserScript instancesRespondToSelector:sel]) return nil;
    @try {
        WKUserScript *s = [WKUserScript alloc];
        return ((id (*)(id, SEL, id, NSInteger, BOOL, id, id, id, id, BOOL))objc_msgSend)(s, sel, src, (NSInteger)when, mainOnly, inc, exc.count ? exc : nil, nil, world, NO);
    } @catch (NSException *x) { return nil; }
}

- (void)install:(WKUserContentController *)ucc config:(WKWebViewConfiguration *)cfg {
    if (![cfg urlSchemeHandlerForURLScheme:@"chrome-extension"]) [cfg setURLSchemeHandler:self forURLScheme:@"chrome-extension"];
    if (_installed) return;
    _installed = YES;
    if (!_exts.count) return;
    WKContentWorld *page = WKContentWorld.pageWorld;
    [ucc addScriptMessageHandlerWithReply:self contentWorld:page name:@"flintExt"];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:[self shimFor:@"page" ext:nil] injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:page]];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:[self shimFor:@"external" ext:nil] injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:page]];
    for (FExt *e in _exts.allValues) {
        [ucc addScriptMessageHandlerWithReply:self contentWorld:e.world name:@"flintExt"];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:[self shimFor:@"content" ext:e] injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:e.world]];
        for (NSDictionary *cs in e.manifest[@"content_scripts"] ?: @[]) for (WKUserScript *us in [self userScriptsFor:cs ext:e]) [ucc addUserScript:us];
    }
    _ucc = ucc;
    [self addRegisteredScripts];
}

// One content-script entry (from the manifest, or registered at run time in manifest form) → WebKit user scripts.
- (NSArray<WKUserScript *> *)userScriptsFor:(NSDictionary *)cs ext:(FExt *)e {
    NSMutableArray *out = [NSMutableArray array];
    if (![cs isKindOfClass:NSDictionary.class]) return out;
    BOOL mainWorld = [cs[@"world"] isEqual:@"MAIN"];
    // user scripts (chrome.userScripts) get a world of their own, apart from the extension's content scripts
    WKContentWorld *world = mainWorld ? WKContentWorld.pageWorld : [cs[@"world"] isEqual:@"USER_SCRIPT"] ? [WKContentWorld worldWithName:[@"flint-us-" stringByAppendingString:e.ident]] : e.world;
    BOOL mainOnly = ![cs[@"all_frames"] boolValue];
    NSString *at = [cs[@"run_at"] isKindOfClass:NSString.class] ? cs[@"run_at"] : @"document_idle";
    WKUserScriptInjectionTime when = [at isEqualToString:@"document_start"] ? WKUserScriptInjectionTimeAtDocumentStart : WKUserScriptInjectionTimeAtDocumentEnd;
    NSArray *inc = ChromePatterns(cs[@"matches"]), *exc = ChromePatterns(cs[@"exclude_matches"]);
    // CSS first, then each JS file as its own script in the same scope, exactly like Chrome
    // (so one file's top-level `const config` is visible to the next).
    NSMutableArray<NSString *> *pieces = [NSMutableArray array];
    NSMutableString *css = [NSMutableString string];
    for (NSString *f in [cs[@"css"] isKindOfClass:NSArray.class] ? cs[@"css"] : @[]) {
        NSString *text = [NSString stringWithContentsOfFile:[e.dir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSString *lit = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[text] options:0 error:nil] encoding:NSUTF8StringEncoding];
        [css appendFormat:@"(()=>{const s=document.createElement('style');s.textContent=%@[0];const put=()=>(document.head||document.documentElement).appendChild(s);document.documentElement?put():document.addEventListener('readystatechange',put,{once:true});})();\n", lit];
    }
    if (css.length) [pieces addObject:css];
    // scripts as files (content scripts) or a mix of files and inline code, in order (user scripts)
    NSMutableArray *sources = [NSMutableArray array];
    for (NSString *f in [cs[@"js"] isKindOfClass:NSArray.class] ? cs[@"js"] : @[]) if ([f isKindOfClass:NSString.class]) [sources addObject:@{@"file": f}];
    for (NSDictionary *p in [cs[@"pieces"] isKindOfClass:NSArray.class] ? cs[@"pieces"] : @[]) if ([p isKindOfClass:NSDictionary.class]) [sources addObject:p];
    for (NSDictionary *src in sources) {
        NSString *f = [src[@"file"] isKindOfClass:NSString.class] ? src[@"file"] : [NSString stringWithFormat:@"userscript-%lu.js", (unsigned long)pieces.count];
        NSString *text = [src[@"code"] isKindOfClass:NSString.class] ? src[@"code"] : [NSString stringWithContentsOfFile:[e.dir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
        if (!text) continue;
        // page-world scripts expect Chrome's requestIdleCallback, which WebKit lacks
        if (mainWorld) text = [PageWorldPolyfills() stringByAppendingString:text];
        [pieces addObject:[text stringByAppendingFormat:@"\n//# sourceURL=chrome-extension://%@/%@", e.ident, [f hasPrefix:@"/"] ? [f substringFromIndex:1] : f]];
    }
    for (NSString *src in pieces) {
        WKUserScript *us = MatchedScript(src, when, mainOnly, inc, exc, world);
        if (!us) {   // older WebKit without per-site scripts: check the address in JavaScript (files then share no top-level scope)
            NSString *matches = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:cs[@"matches"] ?: @[] options:0 error:nil] encoding:NSUTF8StringEncoding];
            NSString *excludes = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:cs[@"exclude_matches"] ?: @[] options:0 error:nil] encoding:NSUTF8StringEncoding];
            NSString *wrapped = [NSString stringWithFormat:@"{\n%@if (__flintMatch(%@, location.href) && !__flintMatch(%@, location.href)) {\n%@\n}\n}\n", mainWorld ? MatchJS() : @"", matches, excludes, src];
            us = [[WKUserScript alloc] initWithSource:wrapped injectionTime:when forMainFrameOnly:mainOnly inContentWorld:world];
        }
        [out addObject:us];
    }
    return out;
}

#pragma mark Scripts registered at run time (chrome.scripting.registerContentScripts)

// Chrome's RegisteredContentScript → the manifest's content_scripts form
static NSDictionary *ManifestFormOf(NSDictionary *r) {
    NSMutableDictionary *cs = [NSMutableDictionary dictionary];
    if (r[@"js"]) cs[@"js"] = r[@"js"];
    if (r[@"css"]) cs[@"css"] = r[@"css"];
    if (r[@"matches"]) cs[@"matches"] = r[@"matches"];
    if (r[@"excludeMatches"]) cs[@"exclude_matches"] = r[@"excludeMatches"];
    if (r[@"allFrames"]) cs[@"all_frames"] = r[@"allFrames"];
    if (r[@"runAt"]) cs[@"run_at"] = r[@"runAt"];
    if (r[@"world"]) cs[@"world"] = r[@"world"];
    return cs;
}
- (void)addRegisteredScripts {
    if (!_ucc) return;
    for (FExt *e in _exts.allValues) {
        for (NSDictionary *r in _regScripts[e.ident] ?: @[]) for (WKUserScript *us in [self userScriptsFor:ManifestFormOf(r) ext:e]) { [_dynScripts addObject:us]; [_ucc addUserScript:us]; }
        for (NSDictionary *r in _userScripts[e.ident] ?: @[]) {
            NSMutableDictionary *cs = [ManifestFormOf(r) mutableCopy]; [cs removeObjectForKey:@"js"];
            cs[@"pieces"] = [r[@"js"] isKindOfClass:NSArray.class] ? r[@"js"] : @[];
            cs[@"world"] = [r[@"world"] isEqual:@"MAIN"] ? @"MAIN" : @"USER_SCRIPT";
            for (WKUserScript *us in [self userScriptsFor:cs ext:e]) { [_dynScripts addObject:us]; [_ucc addUserScript:us]; }
        }
    }
}
// Swap the old set for the new: everything else in the controller stays exactly as it was. Pages pick it up as they load.
- (void)resyncRegisteredScripts {
    if (!_ucc) return;
    NSMutableArray *keep = [NSMutableArray array];
    for (WKUserScript *us in _ucc.userScripts) if (![_dynScripts containsObject:us]) [keep addObject:us];
    [_ucc removeAllUserScripts];
    [_dynScripts removeAllObjects];
    for (WKUserScript *us in keep) [_ucc addUserScript:us];
    [self addRegisteredScripts];
}
- (void)saveRegistered:(FExt *)e {
    NSMutableArray *persist = [NSMutableArray array];
    for (NSDictionary *r in _regScripts[e.ident]) if (![r[@"persistAcrossSessions"] isEqual:@NO]) [persist addObject:r];
    [[NSJSONSerialization dataWithJSONObject:persist options:0 error:nil] writeToFile:[self storePath:e area:@"scripts"] atomically:YES];
    [[NSJSONSerialization dataWithJSONObject:_userScripts[e.ident] ?: @[] options:0 error:nil] writeToFile:[self storePath:e area:@"userscripts"] atomically:YES];
}
// chrome.scripting.*ContentScripts and chrome.userScripts.* share one implementation (same shape, different list)
- (void)registeredOp:(NSString *)op ext:(FExt *)e arg:(id)a ok:(void (^)(id))ok fail:(void (^)(NSString *))fail {
    BOOL user = [op hasPrefix:@"userScripts."];
    if (user) op = @{@"userScripts.register": @"scripting.registerContentScripts", @"userScripts.update": @"scripting.updateContentScripts",
                      @"userScripts.unregister": @"scripting.unregisterContentScripts", @"userScripts.getScripts": @"scripting.getRegisteredContentScripts"}[op] ?: op;
    NSMutableDictionary *store = user ? _userScripts : _regScripts;
    NSMutableArray *list = store[e.ident] ?: (store[e.ident] = [NSMutableArray array]);
    NSSet *ids = [a isKindOfClass:NSDictionary.class] && [a[@"ids"] isKindOfClass:NSArray.class] ? [NSSet setWithArray:a[@"ids"]] : nil;
    if ([op isEqualToString:@"scripting.getRegisteredContentScripts"]) {
        NSMutableArray *out = [NSMutableArray array]; for (NSDictionary *r in list) if (!ids || [ids containsObject:r[@"id"]]) [out addObject:r];
        ok(out); return;
    }
    if ([op isEqualToString:@"scripting.unregisterContentScripts"]) {
        if (ids) for (NSString *i in ids) { BOOL found = NO; for (NSDictionary *r in list) if ([r[@"id"] isEqual:i]) found = YES; if (!found) { fail([NSString stringWithFormat:@"Nonexistent script ID '%@'", i]); return; } }
        [list filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *r, NSDictionary *b) { return ids && ![ids containsObject:r[@"id"]]; }]];
    } else {
        BOOL update = [op isEqualToString:@"scripting.updateContentScripts"];
        for (NSDictionary *r in [a isKindOfClass:NSArray.class] ? a : @[]) {
            if (![r isKindOfClass:NSDictionary.class] || ![r[@"id"] isKindOfClass:NSString.class] || [r[@"id"] hasPrefix:@"_"]) { fail(@"Invalid script ID"); return; }
            NSUInteger at = [list indexOfObjectPassingTest:^BOOL(NSDictionary *x, NSUInteger i, BOOL *stop) { return [x[@"id"] isEqual:r[@"id"]]; }];
            if (!update && at != NSNotFound) { fail([NSString stringWithFormat:@"Duplicate script ID '%@'", r[@"id"]]); return; }
            if (update && at == NSNotFound) { fail([NSString stringWithFormat:@"Script with ID '%@' does not exist", r[@"id"]]); return; }
        }
        for (NSDictionary *r in a) {
            NSUInteger at = [list indexOfObjectPassingTest:^BOOL(NSDictionary *x, NSUInteger i, BOOL *stop) { return [x[@"id"] isEqual:r[@"id"]]; }];
            if (at == NSNotFound) [list addObject:r];
            else { NSMutableDictionary *m = [list[at] mutableCopy]; [m addEntriesFromDictionary:r]; list[at] = m; }
        }
    }
    [self saveRegistered:e];
    [self resyncRegisteredScripts];
    ok(nil);
}

#pragma mark Context menus (chrome.contextMenus)

- (void)menuOp:(NSString *)op ext:(FExt *)e args:(NSArray *)args ok:(void (^)(id))ok fail:(void (^)(NSString *))fail {
    NSMutableArray *items = _menus[e.ident] ?: (_menus[e.ident] = [NSMutableArray array]);
    id a0 = args.count ? args[0] : nil, a1 = args.count > 1 ? args[1] : nil;
    NSUInteger (^find)(id) = ^NSUInteger(id ident) { return [items indexOfObjectPassingTest:^BOOL(NSDictionary *x, NSUInteger i, BOOL *stop) { return [x[@"id"] isEqual:ident]; }]; };
    if ([op isEqualToString:@"contextMenus.create"]) {
        NSMutableDictionary *p = [a0 isKindOfClass:NSDictionary.class] ? [a0 mutableCopy] : nil;
        if (!p || !p[@"id"]) { fail(@"Invalid menu item"); return; }
        if (find(p[@"id"]) != NSNotFound) { fail([NSString stringWithFormat:@"Cannot create item with duplicate id %@", p[@"id"]]); return; }
        if (p[@"parentId"] && find(p[@"parentId"]) == NSNotFound) { fail([NSString stringWithFormat:@"Cannot find menu item with id %@", p[@"parentId"]]); return; }
        [items addObject:p]; ok(p[@"id"]);
    } else if ([op isEqualToString:@"contextMenus.update"]) {
        NSUInteger i = find(a0); if (i == NSNotFound) { fail([NSString stringWithFormat:@"Cannot find menu item with id %@", a0]); return; }
        if ([a1 isKindOfClass:NSDictionary.class]) [items[i] addEntriesFromDictionary:a1];
        ok(nil);
    } else if ([op isEqualToString:@"contextMenus.remove"]) {
        if (find(a0) == NSNotFound) { fail([NSString stringWithFormat:@"Cannot find menu item with id %@", a0]); return; }
        NSMutableSet *gone = [NSMutableSet setWithObject:a0];   // and everything under it
        BOOL more = YES; while (more) { more = NO; for (NSDictionary *x in items) if (x[@"parentId"] && [gone containsObject:x[@"parentId"]] && ![gone containsObject:x[@"id"]]) { [gone addObject:x[@"id"]]; more = YES; } }
        [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *x, NSDictionary *b) { return ![gone containsObject:x[@"id"]]; }]];
        ok(nil);
    } else if ([op isEqualToString:@"contextMenus.removeAll"]) { [items removeAllObjects]; ok(nil); }
    else fail([@"Flint doesn't support " stringByAppendingString:op]);
}

static BOOL MenuPatternsMatch(id patterns, NSString *url) {
    if (![patterns isKindOfClass:NSArray.class] || ![patterns count]) return YES;
    if (!url.length) return NO;
    for (NSString *p in patterns) {
        if (![p isKindOfClass:NSString.class]) continue;
        if ([p isEqualToString:@"<all_urls>"]) { if ([url hasPrefix:@"http"] || [url hasPrefix:@"file:"]) return YES; continue; }
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"^(\\*|https?|file|ftp|wss?)://([^/]*)(/.*)$" options:0 error:nil];
        NSTextCheckingResult *m = [rx firstMatchInString:p options:0 range:NSMakeRange(0, p.length)]; if (!m) continue;
        NSString *scheme = [p substringWithRange:[m rangeAtIndex:1]], *host = [p substringWithRange:[m rangeAtIndex:2]], *path = [p substringWithRange:[m rangeAtIndex:3]];
        NSString *(^esc)(NSString *) = ^NSString *(NSString *s) { return [NSRegularExpression escapedPatternForString:s]; };
        NSString *sx = [scheme isEqualToString:@"*"] ? @"(https?|wss?)" : esc(scheme);
        NSString *hx = [host isEqualToString:@"*"] ? @"[^/]*" : [host hasPrefix:@"*."] ? [@"([^/]*\\.)?" stringByAppendingString:esc([host substringFromIndex:2])] : esc(host);
        NSString *px = [esc(path) stringByReplacingOccurrencesOfString:@"\\*" withString:@".*"];
        NSRegularExpression *full = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^%@://%@(:\\d+)?%@$", sx, hx, px] options:0 error:nil];
        if ([full firstMatchInString:url options:0 range:NSMakeRange(0, url.length)]) return YES;
    }
    return NO;
}

// Add every extension's items that apply to what was right-clicked. One item shows as itself; several go
// under the extension's name, as in Chrome.
- (void)addMenuItemsTo:(NSMenu *)menu context:(NSDictionary *)c pageURL:(NSString *)page view:(WKWebView *)v {
    NSString *(^str)(NSString *) = ^NSString *(NSString *k) { id x = c[k]; return [x isKindOfClass:NSString.class] && [x length] ? x : nil; };
    NSString *link = str(@"link"), *image = str(@"image"), *video = str(@"video"), *sel = str(@"selection");
    BOOL editable = [c[@"editable"] boolValue];
    NSMutableSet *here = [NSMutableSet setWithObject:@"all"];
    if (link) [here addObject:@"link"];
    if (image) [here addObject:@"image"];
    if (video) { [here addObject:@"video"]; [here addObject:@"audio"]; }
    if (sel) [here addObject:@"selection"];
    if (editable) [here addObject:@"editable"];
    if (!link && !image && !video && !sel && !editable) [here addObject:@"page"];
    VTab *tab = TabForView(v);
    BOOL first = YES;
    for (FExt *e in self.extensions) {
        NSArray *items = _menus[e.ident]; if (!items.count) continue;
        BOOL (^applies)(NSDictionary *) = ^BOOL(NSDictionary *x) {
            if ([x[@"visible"] isEqual:@NO]) return NO;
            NSArray *ctx = [x[@"contexts"] isKindOfClass:NSArray.class] ? x[@"contexts"] : @[@"page"];
            BOOL hit = NO; for (NSString *k in ctx) if ([here containsObject:k]) hit = YES;
            if (!hit) return NO;
            if (!MenuPatternsMatch(x[@"documentUrlPatterns"], page)) return NO;
            NSString *target = link ?: image ?: video;
            if (x[@"targetUrlPatterns"] && target && !MenuPatternsMatch(x[@"targetUrlPatterns"], target)) return NO;
            return YES;
        };
        NSMenuItem *(^build)(NSDictionary *) = nil;
        __block __weak NSMenuItem *(^weakBuild)(NSDictionary *);
        build = ^NSMenuItem *(NSDictionary *x) {
            if ([x[@"type"] isEqual:@"separator"]) return NSMenuItem.separatorItem;
            NSString *t = [x[@"title"] isKindOfClass:NSString.class] ? x[@"title"] : e.name;
            if (sel) t = [t stringByReplacingOccurrencesOfString:@"%s" withString:sel.length > 30 ? [[sel substringToIndex:29] stringByAppendingString:@"…"] : sel];
            NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:t action:@selector(extMenuClicked:) keyEquivalent:@""];
            it.target = self; it.enabled = ![x[@"enabled"] isEqual:@NO];
            if ([x[@"type"] isEqual:@"checkbox"] || [x[@"type"] isEqual:@"radio"]) it.state = [x[@"checked"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            NSMutableDictionary *info = [@{@"menuItemId": x[@"id"], @"editable": @(editable)} mutableCopy];
            if (x[@"parentId"]) info[@"parentMenuItemId"] = x[@"parentId"];
            if (page) { info[@"pageUrl"] = page; info[@"frameUrl"] = page; }
            if (link) info[@"linkUrl"] = link;
            if (image) { info[@"srcUrl"] = image; info[@"mediaType"] = @"image"; }
            else if (video) { info[@"srcUrl"] = video; info[@"mediaType"] = @"video"; }
            if (sel) info[@"selectionText"] = sel;
            it.representedObject = @{@"ext": e.ident, @"item": x, @"info": info, @"tab": tab ? TabInfo(tab) : @{}};
            NSMutableArray *kids = [NSMutableArray array];
            for (NSDictionary *k in items) if ([k[@"parentId"] isEqual:x[@"id"]] && applies(k)) [kids addObject:k];
            if (kids.count) {
                NSMenu *sub = [[NSMenu alloc] initWithTitle:t];
                for (NSDictionary *k in kids) [sub addItem:weakBuild(k)];
                it.submenu = sub; it.action = nil;
            }
            return it;
        };
        weakBuild = build;
        NSMutableArray *top = [NSMutableArray array];
        for (NSDictionary *x in items) if (!x[@"parentId"] && applies(x)) [top addObject:x];
        if (!top.count) continue;
        if (first) { [menu addItem:NSMenuItem.separatorItem]; first = NO; }
        NSImage *icon = [self iconFor:e]; if (icon) { icon = [icon copy]; icon.size = NSMakeSize(16, 16); }
        if (top.count == 1) { NSMenuItem *it = build(top[0]); if (!it.isSeparatorItem) it.image = icon; [menu addItem:it]; }
        else {
            NSMenuItem *group = [[NSMenuItem alloc] initWithTitle:e.name action:nil keyEquivalent:@""];
            group.image = icon;
            NSMenu *sub = [[NSMenu alloc] initWithTitle:e.name];
            for (NSDictionary *x in top) [sub addItem:build(x)];
            group.submenu = sub;
            [menu addItem:group];
        }
    }
}

- (void)extMenuClicked:(NSMenuItem *)it {
    NSDictionary *r = it.representedObject; FExt *e = _exts[r[@"ext"] ?: @""]; if (!e) return;
    NSMutableDictionary *item = nil;
    for (NSMutableDictionary *x in _menus[e.ident]) if ([x[@"id"] isEqual:r[@"item"][@"id"]]) item = x;
    NSMutableDictionary *info = [r[@"info"] mutableCopy];
    if ([item[@"type"] isEqual:@"checkbox"]) { BOOL was = [item[@"checked"] boolValue]; item[@"checked"] = @(!was); info[@"wasChecked"] = @(was); info[@"checked"] = @(!was); }
    else if ([item[@"type"] isEqual:@"radio"]) {   // one of its group (same parent) is on
        BOOL was = [item[@"checked"] boolValue];
        for (NSMutableDictionary *x in _menus[e.ident]) if ([x[@"type"] isEqual:@"radio"] && ((!x[@"parentId"] && !item[@"parentId"]) || [x[@"parentId"] isEqual:item[@"parentId"]])) x[@"checked"] = @NO;
        item[@"checked"] = @YES; info[@"wasChecked"] = @(was); info[@"checked"] = @YES;
    }
    [self toBackground:e body:@"return globalThis.__flintMenuClicked ? __flintMenuClicked(info, tab) : false" args:@{@"info": info, @"tab": r[@"tab"] ?: @{}} done:nil];
}

#pragma mark Background pages

- (void)start { for (FExt *e in self.extensions) { if (!e.bgQueue) e.bgQueue = [NSMutableArray array]; [self startBackground:e]; } }
// CPU time a process has used so far, in seconds (the CPU rule reads this for every helper).
static double ProcessCPUSeconds(pid_t pid) {
    struct rusage_info_v2 ri;
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&ri) != 0) return 0;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    return (double)(ri.ri_user_time + ri.ri_system_time) * tb.numer / tb.denom / 1e9;
}

- (void)startBackground:(FExt *)e {
    NSDictionary *bg = e.manifest[@"background"];
    if (![bg isKindOfClass:NSDictionary.class]) { e.bgReady = YES; return; }
    // an offscreen window keeps the page's timers running at full speed
    e.bgWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 400, 300) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    e.background = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:FlintConfig()];
    if (@available(macOS 13.3, *)) e.background.inspectable = YES;
    e.bgWindow.contentView = e.background;
    [e.bgWindow orderBack:nil];
    e.bgWindow.alphaValue = 0;
    e.bgWindow.ignoresMouseEvents = YES;
    [e.background loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"chrome-extension://%@/__flint_background.html", e.ident]]]];
    // once its scripts have run, tell it it's installed / started
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        e.bgReady = YES;
        NSString *flag = [NSString stringWithFormat:@"extInstalled.%@", e.ident];
        NSString *reason = [Defaults() boolForKey:flag] ? @"update" : @"install";
        [Defaults() setBool:YES forKey:flag];
        [self call:@"return __flintInstalled(d)" args:@{@"d": @{@"reason": reason}} view:e.background world:WKContentWorld.pageWorld frame:nil done:nil];
        NSArray *q = e.bgQueue.copy; [e.bgQueue removeAllObjects];
        for (void (^b)(void) in q) b();
    });
}

- (NSData *)backgroundHTML:(FExt *)e {
    NSDictionary *bg = e.manifest[@"background"];
    NSMutableString *h = [NSMutableString stringWithString:@"<!doctype html><meta charset=utf-8><title>background</title>\n"];
    if ([bg[@"service_worker"] isKindOfClass:NSString.class])
        [h appendFormat:@"<script src=\"/%@\"%@></script>\n", [bg[@"service_worker"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]], [bg[@"type"] isEqual:@"module"] ? @" type=\"module\"" : @""];
    for (NSString *s in bg[@"scripts"] ?: @[]) [h appendFormat:@"<script src=\"/%@\"></script>\n", [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]];
    if ([bg[@"page"] isKindOfClass:NSString.class]) {
        NSString *page = [NSString stringWithContentsOfFile:[e.dir stringByAppendingPathComponent:bg[@"page"]] encoding:NSUTF8StringEncoding error:nil];
        if (page) return [page dataUsingEncoding:NSUTF8StringEncoding];
    }
    return [h dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)call:(NSString *)body args:(NSDictionary *)args view:(WKWebView *)v world:(WKContentWorld *)w frame:(WKFrameInfo *)f done:(void (^)(id, NSError *))done {
    if (!v) { if (done) done(nil, [NSError errorWithDomain:@"flint" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Receiving end does not exist."}]); return; }
    [v callAsyncJavaScript:body arguments:args inFrame:f inContentWorld:w completionHandler:^(id r, NSError *e) { if (done) done(r, e); }];
}

- (void)toBackground:(FExt *)e body:(NSString *)body args:(NSDictionary *)args done:(void (^)(id, NSError *))done {
    if (!e.background) { if (done) done(nil, [NSError errorWithDomain:@"flint" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not establish connection. Receiving end does not exist."}]); return; }
    void (^go)(void) = ^{ [self call:body args:args view:e.background world:WKContentWorld.pageWorld frame:nil done:done]; };
    if (e.bgReady) go(); else [e.bgQueue addObject:[go copy]];
}

#pragma mark Tabs → extensions

- (void)tab:(VTab *)t event:(NSString *)kind {
    if (!t || !_exts.count || t.owner.isPrivate) return;
    NSDictionary *info = TabInfo(t);
    for (FExt *e in _exts.allValues) {
        if (!e.bgReady) continue;
        if ([kind isEqualToString:@"loading"] || [kind isEqualToString:@"complete"]) {
            NSMutableDictionary *change = [@{@"status": kind} mutableCopy];
            if ([kind isEqualToString:@"loading"] && t.url) change[@"url"] = t.url;
            [self call:@"return __flintTabEvent('updated', id, c, t)" args:@{@"id": @(TabID(t)), @"c": change, @"t": info} view:e.background world:WKContentWorld.pageWorld frame:nil done:nil];
        } else if ([kind isEqualToString:@"activated"]) {
            [self call:@"return __flintTabEvent('activated', a)" args:@{@"a": @{@"tabId": @(TabID(t)), @"windowId": @1}} view:e.background world:WKContentWorld.pageWorld frame:nil done:nil];
        } else if ([kind isEqualToString:@"removed"]) {
            [self call:@"return __flintTabEvent('removed', id, i)" args:@{@"id": @(TabID(t)), @"i": @{@"windowId": @1, @"isWindowClosing": @NO}} view:e.background world:WKContentWorld.pageWorld frame:nil done:nil];
        }
    }
}

#pragma mark chrome.* calls from JavaScript

- (NSDictionary *)senderFor:(WKScriptMessage *)m ext:(FExt *)e {
    NSMutableDictionary *s = [@{@"id": e.ident} mutableCopy];
    NSURL *u = m.frameInfo.request.URL;
    if (u) s[@"url"] = u.absoluteString;
    WKSecurityOrigin *o = m.frameInfo.securityOrigin;
    s[@"origin"] = o.port ? [NSString stringWithFormat:@"%@://%@:%ld", o.protocol, o.host, (long)o.port] : [NSString stringWithFormat:@"%@://%@", o.protocol, o.host];
    VTab *t = TabForView(m.webView);
    if (t) { s[@"tab"] = TabInfo(t); s[@"frameId"] = FrameIDFor(m.frameInfo); }
    return s;
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)m replyHandler:(void (^)(id, NSString *))reply {
    NSDictionary *msg = [m.body isKindOfClass:NSDictionary.class] ? m.body : nil;
    NSString *op = msg[@"op"];
    NSArray *args = [msg[@"args"] isKindOfClass:NSArray.class] ? msg[@"args"] : @[];
    FExt *e = _exts[msg[@"ext"] ?: @""];
    if (!e || !op) { reply(nil, @"unknown extension"); return; }
    if (gExtDebug) DLog(@"ext op %@ %@ (%@%@)", e.name, op, m.world == WKContentWorld.pageWorld ? @"page" : @"content", m.frameInfo.isMainFrame ? @"" : @", subframe");
    if ([op isEqualToString:@"debug.log"]) {   // development only: errors the extension hit
        NSString *t = [args.firstObject isKindOfClass:NSString.class] ? args.firstObject : @"";
        if (gExtDebug) DLog(@"ext %@ console: %@", e.name, t.length > 400 ? [t substringToIndex:400] : t);
        reply(NSNull.null, nil); return;
    }
    WKContentWorld *world = m.world;
    RememberFrame(m.webView, m.frameInfo);
    BOOL fromPage = world == WKContentWorld.pageWorld;
    NSString *proto = m.frameInfo.securityOrigin.protocol;
    // who may call: the extension's own pages, its content world, and its externally_connectable sites
    if (fromPage && ![proto isEqualToString:@"chrome-extension"]) {
        if (![op isEqualToString:@"runtime.sendMessageExternal"]) { reply(nil, @"not allowed"); return; }
    } else if (fromPage && ![m.frameInfo.securityOrigin.host isEqualToString:e.ident]) { reply(nil, @"not allowed"); return; }
    else if (!fromPage && world != e.world) { reply(nil, @"not allowed"); return; }

    id (^arg)(NSUInteger) = ^id(NSUInteger i) { id v = i < args.count ? args[i] : nil; return v == NSNull.null ? nil : v; };
    void (^ok)(id) = ^(id v) { reply(v ?: NSNull.null, nil); };
    void (^fail)(NSString *) = ^(NSString *why) { reply(@{@"__error": why ?: @"error"}, nil); };

    if ([op isEqualToString:@"runtime.sendMessage"] || [op isEqualToString:@"runtime.sendMessageExternal"]) {
        BOOL ext = [op hasSuffix:@"External"];
        if (m.webView == e.background) { ok(nil); return; }   // background → itself isn't delivered (popup listeners not tracked yet)
        NSMutableDictionary *sender = [[self senderFor:m ext:e] mutableCopy];
        if (ext) [sender removeObjectForKey:@"id"];   // like Chrome: messages from web pages carry no extension id
        [self toBackground:e body:@"return await __flintOnMessage(msg, sender, external)" args:@{@"msg": arg(0) ?: NSNull.null, @"sender": sender, @"external": @(ext)}
                      done:^(id r, NSError *err) {
            if (ext || gExtDebug) DLog(@"ext msg%@ from %@: %@ → %@ %@", ext ? @" (external)" : @"", m.frameInfo.securityOrigin.host, [self brief:arg(0)], [self brief:r], err.localizedDescription ?: @"");
            if (err) fail(err.localizedDescription); else ok(r); }];
    }
    else if ([op isEqualToString:@"runtime.connect"]) {
        FPort *p = [FPort new]; p.ident = arg(0);
        p.aView = m.webView; p.aWorld = world; p.aFrame = m.frameInfo;
        p.bView = e.background; p.bWorld = WKContentWorld.pageWorld;
        if (!p.ident || !e.background) { ok(@NO); return; }
        _ports[p.ident] = p;
        [self toBackground:e body:@"return __flintOnConnect(id, name, sender, false)" args:@{@"id": p.ident, @"name": arg(1) ?: @"", @"sender": [self senderFor:m ext:e]}
                      done:^(id r, NSError *err) { ok(@(err == nil)); }];
    }
    else if ([op isEqualToString:@"port.post"] || [op isEqualToString:@"port.disconnect"]) {
        FPort *p = _ports[arg(0) ?: @""]; if (!p) { ok(@NO); return; }
        BOOL fromA = m.webView == p.aView && world == p.aWorld;
        WKWebView *v = fromA ? p.bView : p.aView; WKContentWorld *w = fromA ? p.bWorld : p.aWorld;
        WKFrameInfo *f = fromA ? nil : p.aFrame;
        BOOL post = [op isEqualToString:@"port.post"];
        if (gExtDebug) DLog(@"ext port %@ %@ %@: %@", p.ident, fromA ? @"→bg" : @"→page", post ? @"msg" : @"disconnect", [self brief:arg(1)]);
        if (!post) [_ports removeObjectForKey:p.ident];
        [self call:@"return __flintPortEvent(id, kind, data)" args:@{@"id": p.ident, @"kind": post ? @"message" : @"disconnect", @"data": arg(1) ?: NSNull.null}
              view:v world:w frame:f done:^(id r, NSError *err) { if (err && f) [self call:@"return __flintPortEvent(id, kind, data)" args:@{@"id": p.ident, @"kind": post ? @"message" : @"disconnect", @"data": arg(1) ?: NSNull.null} view:v world:w frame:nil done:nil]; }];
        ok(@YES);
    }
    else if ([op hasPrefix:@"storage."]) [self storageOp:op ext:e args:args ok:ok];
    else if ([op isEqualToString:@"tabs.query"]) {
        NSDictionary *q = arg(0) ?: @{};
        NSMutableArray *out = [NSMutableArray array];
        BOOL thisWin = [q[@"currentWindow"] boolValue] || [q[@"lastFocusedWindow"] boolValue];
        for (VTab *t in AllTabs(NO)) {
            if (thisWin && t.owner != NormalWin()) continue;
            if ([q[@"windowId"] isKindOfClass:NSNumber.class] && [q[@"windowId"] integerValue] > 0 && WinID(t.owner) != [q[@"windowId"] integerValue]) continue;
            if ([q[@"active"] isKindOfClass:NSNumber.class] && [q[@"active"] boolValue] != (t == t.owner.current)) continue;
            if (q[@"url"]) { NSString *pat = [q[@"url"] isKindOfClass:NSString.class] ? q[@"url"] : nil; if (pat && ![pat isEqualToString:@"<all_urls>"] && ![t.url ?: @"" hasPrefix:[pat stringByReplacingOccurrencesOfString:@"*" withString:@""]]) continue; }
            [out addObject:TabInfo(t)];
        }
        ok(out);
    }
    else if ([op isEqualToString:@"tabs.get"]) { NSDictionary *i = TabInfo(TabForID([arg(0) integerValue])); if (i) ok(i); else fail(@"No tab with id"); }
    else if ([op isEqualToString:@"tabs.getCurrent"]) ok(TabInfo(TabForView(m.webView)));
    else if ([op isEqualToString:@"tabs.create"]) {
        NSDictionary *p = arg(0) ?: @{};
        NSString *u = p[@"url"]; if ([u isKindOfClass:NSString.class] && ![u containsString:@":"]) u = [NSString stringWithFormat:@"chrome-extension://%@/%@", e.ident, [u hasPrefix:@"/"] ? [u substringFromIndex:1] : u];
        VWindow *w = NormalWin(); NSArray *before = w.tabs.copy;
        [w newTab:[NSURL URLWithString:u ?: @""] select:p[@"active"] ? [p[@"active"] boolValue] : YES];
        VTab *made = nil; for (VTab *t in w.tabs) if (![before containsObject:t]) made = t;
        ok(TabInfo(made ?: w.current));
    }
    else if ([op isEqualToString:@"tabs.update"]) {
        BOOL hasId = args.count >= 2;
        VTab *t = hasId ? TabForID([arg(0) integerValue]) : NormalWin().current;
        NSDictionary *p = (hasId ? arg(1) : arg(0)) ?: @{};
        if (!t) { fail(@"No tab with id"); return; }
        if ([p[@"url"] isKindOfClass:NSString.class]) { if (!t.web) [t.owner selectTab:t]; [t.web open:p[@"url"] record:YES]; }
        if ([p[@"active"] boolValue]) [t.owner selectTab:t];
        ok(TabInfo(t));
    }
    else if ([op isEqualToString:@"tabs.remove"]) {
        id ids = arg(0); for (NSNumber *n in [ids isKindOfClass:NSArray.class] ? ids : @[ids ?: @0]) { VTab *t = TabForID(n.integerValue); if (t) [t.owner closeTab:t]; }
        ok(nil);
    }
    else if ([op isEqualToString:@"tabs.reload"]) { VTab *t = arg(0) ? TabForID([arg(0) integerValue]) : NormalWin().current; [t.web reload]; ok(nil); }
    else if ([op isEqualToString:@"tabs.sendMessage"]) {
        VTab *t = TabForID([arg(0) integerValue]);
        if (!t.web.web) { fail(@"Could not establish connection. Receiving end does not exist."); return; }
        NSMutableDictionary *sender = [@{@"id": e.ident} mutableCopy];
        if (m.frameInfo.request.URL) sender[@"url"] = m.frameInfo.request.URL.absoluteString;
        // options.frameId: one frame of the tab (one that has talked to the extension), otherwise the page
        NSDictionary *opts = [arg(2) isKindOfClass:NSDictionary.class] ? arg(2) : nil;
        WKFrameInfo *fi = nil;
        if ([opts[@"frameId"] isKindOfClass:NSNumber.class] && [opts[@"frameId"] longLongValue] != 0) { fi = [gFrames objectForKey:t.web.web][opts[@"frameId"]]; if (!fi) { fail(@"Could not establish connection. Receiving end does not exist."); return; } }
        [self call:@"return await __flintOnMessage(msg, sender, false)" args:@{@"msg": arg(1) ?: NSNull.null, @"sender": sender} view:t.web.web world:e.world frame:fi
              done:^(id r, NSError *err) { if (err) fail(@"Could not establish connection. Receiving end does not exist."); else ok(r); }];
    }
    else if ([op isEqualToString:@"scripting.executeScript"] || [op isEqualToString:@"scripting.insertCSS"] || [op isEqualToString:@"scripting.removeCSS"]) [self scripting:op ext:e details:arg(0) ok:ok fail:fail];
    else if (([op hasPrefix:@"scripting."] && [op hasSuffix:@"ContentScripts"]) || [op hasPrefix:@"userScripts."]) [self registeredOp:op ext:e arg:arg(0) ok:ok fail:fail];
    else if ([op hasPrefix:@"dnr."]) [FDNR.shared op:op ext:e.ident args:args reply:^(id r, NSString *err) { if (err) fail(err); else ok(r); }];
    else if ([op hasPrefix:@"contextMenus."]) [self menuOp:op ext:e args:args ok:ok fail:fail];
    else if ([op isEqualToString:@"action.openPopup"]) { [self openPopup:e from:nil]; ok(nil); }
    else if ([op isEqualToString:@"runtime.openOptionsPage"]) {
        [self openOptions:e];
        ok(nil);
    }
    else if ([op isEqualToString:@"runtime.reload"]) { [e.background reload]; ok(nil); }
    else if ([op isEqualToString:@"net.fetch"]) [self fetch:arg(0) ok:ok];
    else { DLog(@"ext unsupported op %@", op); fail([@"Flint doesn't support " stringByAppendingString:op]); }
}

- (NSString *)brief:(id)o {
    if (!o) return @"nil";
    if ([o isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:@"{type:%@}", o[@"type"] ?: @"?"];
    return [o isKindOfClass:NSString.class] ? @"<string>" : NSStringFromClass([o class]);
    NSData *d = [NSJSONSerialization isValidJSONObject:o] ? [NSJSONSerialization dataWithJSONObject:o options:0 error:nil] : nil;
    NSString *t = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : [o description];
    return t.length > 400 ? [[t substringToIndex:400] stringByAppendingString:@"…"] : t;
}

- (void)storageOp:(NSString *)op ext:(FExt *)e args:(NSArray *)args ok:(void (^)(id))ok {
    NSString *areaName = args.count ? args[0] : @"local";
    NSMutableDictionary *area = e.store[areaName]; if (!area) { ok(@{}); return; }
    id keys = args.count > 1 ? args[1] : nil;
    if ([op isEqualToString:@"storage.get"]) {
        if (!keys || keys == NSNull.null) { ok(area); return; }
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        if ([keys isKindOfClass:NSString.class]) { if (area[keys]) out[keys] = area[keys]; }
        else if ([keys isKindOfClass:NSArray.class]) { for (NSString *k in keys) if (area[k]) out[k] = area[k]; }
        else if ([keys isKindOfClass:NSDictionary.class]) { for (NSString *k in keys) out[k] = area[k] ?: keys[k]; }
        ok(out); return;
    }
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    if ([op isEqualToString:@"storage.set"] && [keys isKindOfClass:NSDictionary.class]) {
        for (NSString *k in keys) { changes[k] = @{@"oldValue": area[k] ?: NSNull.null, @"newValue": keys[k]}; area[k] = keys[k]; }
    } else if ([op isEqualToString:@"storage.remove"]) {
        for (NSString *k in [keys isKindOfClass:NSArray.class] ? keys : (keys ? @[keys] : @[])) if (area[k]) { changes[k] = @{@"oldValue": area[k]}; [area removeObjectForKey:k]; }
    } else if ([op isEqualToString:@"storage.clear"]) {
        for (NSString *k in area) changes[k] = @{@"oldValue": area[k]};
        [area removeAllObjects];
    }
    ok(nil);
    if (!changes.count) return;
    if ([areaName isEqualToString:@"local"] || [areaName isEqualToString:@"sync"]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:area options:0 error:nil];
        [d writeToFile:[self storePath:e area:areaName] atomically:YES];
    }
    // tell every part of the extension (onChanged): background, its pages, its content scripts
    NSDictionary *a = @{@"c": changes, @"a": areaName};
    NSString *body = @"return globalThis.__flintStorageChanged ? __flintStorageChanged(c, a) : false";
    if (e.background) [self call:body args:a view:e.background world:WKContentWorld.pageWorld frame:nil done:nil];
    for (VTab *t in AllTabs(NO)) if (t.web.web) {
        [self call:body args:a view:t.web.web world:e.world frame:nil done:nil];
        if ([t.url hasPrefix:@"chrome-extension://"]) [self call:body args:a view:t.web.web world:WKContentWorld.pageWorld frame:nil done:nil];
    }
    WKWebView *pop = (WKWebView *)_popover.contentViewController.view;
    if (_popover.shown && [pop isKindOfClass:WKWebView.class]) [self call:body args:a view:pop world:WKContentWorld.pageWorld frame:nil done:nil];
}

- (void)scripting:(NSString *)op ext:(FExt *)e details:(NSDictionary *)d ok:(void (^)(id))ok fail:(void (^)(NSString *))fail {
    VTab *t = TabForID([d[@"target"][@"tabId"] integerValue]);
    WKWebView *v = t.web.web;
    if (!v) { fail(@"No tab with id"); return; }
    WKContentWorld *w = [d[@"world"] isEqual:@"MAIN"] ? WKContentWorld.pageWorld : e.world;
    NSArray *frames = TargetFrames(v, [d[@"target"] isKindOfClass:NSDictionary.class] ? d[@"target"] : @{});
    if (!frames.count) { fail(@"No frame with id"); return; }
    NSMutableString *code = [NSMutableString string];
    NSDictionary *jsArgs;
    BOOL css = [op isEqualToString:@"scripting.insertCSS"] || [op isEqualToString:@"scripting.removeCSS"];
    if (css) {
        NSMutableString *text = [NSMutableString stringWithString:[d[@"css"] isKindOfClass:NSString.class] ? d[@"css"] : @""];
        for (NSString *f in [d[@"files"] isKindOfClass:NSArray.class] ? d[@"files"] : @[]) [text appendString:[NSString stringWithContentsOfFile:[e.dir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil] ?: @""];
        // each inserted sheet is labelled with a hash of its text, so the same text can be removed again
        NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding]; unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, h);
        NSMutableString *key = [NSMutableString stringWithString:e.ident]; for (int i = 0; i < 8; i++) [key appendFormat:@"%02x", h[i]];
        if ([op isEqualToString:@"scripting.removeCSS"])
            [code appendString:@"for (const s of document.querySelectorAll('style[data-flint-css]')) if (s.dataset.flintCss === key) { s.remove(); break; } return null;"];
        else [code appendString:@"const s = document.createElement('style'); s.dataset.flintCss = key; s.textContent = css; (document.head || document.documentElement).appendChild(s); return null;"];
        jsArgs = @{@"css": text, @"key": key};
        w = WKContentWorld.pageWorld;   // a style is part of the page whichever world adds it
    } else {
        if ([d[@"func"] isKindOfClass:NSString.class]) [code appendFormat:@"return await (%@)(...args);", d[@"func"]];
        else {
            for (NSString *f in [d[@"files"] isKindOfClass:NSArray.class] ? d[@"files"] : @[]) {
                NSString *t2 = [NSString stringWithContentsOfFile:[e.dir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil];
                if (t2) [code appendFormat:@"%@\n;", t2];
            }
            // run as the body of an injected function: WebKit injects it like a user script, so the page's CSP doesn't apply
            [code appendString:@"\nreturn null;"];
        }
        jsArgs = @{@"args": [d[@"args"] isKindOfClass:NSArray.class] ? d[@"args"] : @[]};
    }
    NSString *shim = w == e.world ? [[self shimFor:@"content" ext:e] stringByAppendingString:@";true"] : nil;
    NSMutableArray *results = [NSMutableArray array];
    __block NSUInteger pending = frames.count;
    for (NSArray *fr in frames) {
        WKFrameInfo *fi = fr[1] == NSNull.null ? nil : fr[1];
        NSNumber *fid = fr[0];
        void (^finished)(id) = ^(id r) {
            [results addObject:@{@"frameId": fid, @"result": r ?: NSNull.null, @"documentId": fid.longLongValue ? fid.stringValue : @"main"}];
            if (--pending == 0) ok(css ? nil : results);
        };
        void (^run)(void) = ^{
            [v callAsyncJavaScript:code arguments:jsArgs inFrame:fi inContentWorld:w completionHandler:^(id r, NSError *err) {
                if (err && !css) DLog(@"executeScript error: %@", err.userInfo[@"WKJavaScriptExceptionMessage"] ?: err.localizedDescription);
                finished(r);
            }];
        };
        if (!shim) { run(); continue; }
        // the extension's own world must have chrome.* before its code runs (a page loaded before the extension, or one
        // its content scripts don't match, has a bare world): give it the API first, as Chrome always does
        [v evaluateJavaScript:@"!!globalThis.__flintExtLoaded" inFrame:fi inContentWorld:w completionHandler:^(id has, NSError *err) {
            if ([has boolValue]) { run(); return; }
            [v evaluateJavaScript:shim inFrame:fi inContentWorld:w completionHandler:^(id r2, NSError *e2) { run(); }];
        }];
    }
}

- (void)fetch:(NSDictionary *)r ok:(void (^)(id))ok {
    NSURL *u = [NSURL URLWithString:r[@"url"] ?: @""];
    if (!u) { ok(@{@"error": @"bad URL"}); return; }
    NSMutableURLRequest *q = [NSMutableURLRequest requestWithURL:u];
    q.HTTPMethod = r[@"method"] ?: @"GET";
    NSDictionary *hs = [r[@"headers"] isKindOfClass:NSDictionary.class] ? r[@"headers"] : @{};
    for (NSString *k in hs) [q setValue:hs[k] forHTTPHeaderField:k];
    if ([r[@"body"] isKindOfClass:NSString.class]) q.HTTPBody = [[NSData alloc] initWithBase64EncodedString:r[@"body"] options:0];
    q.HTTPShouldHandleCookies = ![r[@"credentials"] isEqual:@"omit"];
    [[NSURLSession.sharedSession dataTaskWithRequest:q completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *h = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        NSDictionary *out = err ? @{@"error": err.localizedDescription} :
            @{@"status": @(h.statusCode ?: 200), @"statusText": [NSHTTPURLResponse localizedStringForStatusCode:h.statusCode], @"headers": h.allHeaderFields ?: @{},
              @"body": [d base64EncodedStringWithOptions:0] ?: @"", @"url": resp.URL.absoluteString ?: u.absoluteString};
        dispatch_async(dispatch_get_main_queue(), ^{ ok(out); });
    }] resume];
}

#pragma mark chrome-extension:// files

- (void)webView:(WKWebView *)w startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *u = task.request.URL;
    FExt *e = _exts[u.host.lowercaseString ?: @""];
    NSData *data = nil; NSString *mime = @"text/html";
    if (e) {
        NSString *path = u.path.length ? u.path : @"/";
        if ([path isEqualToString:@"/__flint_background.html"]) data = [self backgroundHTML:e];
        else {
            NSString *file = [[e.dir stringByAppendingPathComponent:path] stringByStandardizingPath];
            if ([file hasPrefix:e.dir]) { data = [NSData dataWithContentsOfFile:file]; mime = MIMEFor(file.pathExtension); }
        }
    }
    NSDictionary *headers = @{@"Content-Type": mime, @"Access-Control-Allow-Origin": @"*", @"Cache-Control": @"no-cache"};
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:u statusCode:data ? 200 : 404 HTTPVersion:@"HTTP/1.1" headerFields:headers];
    @try {
        [task didReceiveResponse:resp];
        [task didReceiveData:data ?: [NSData data]];
        [task didFinish];
    } @catch (NSException *x) {}
}
- (void)webView:(WKWebView *)w stopURLSchemeTask:(id<WKURLSchemeTask>)task {}

#pragma mark Names and icons for the toolbar, address bar and sidebar

- (NSImage *)iconFor:(FExt *)e {
    if (!e) return nil;
    NSDictionary *action = e.manifest[@"action"] ?: e.manifest[@"browser_action"];
    id icons = action[@"default_icon"] ?: e.manifest[@"icons"];
    NSString *path = [icons isKindOfClass:NSString.class] ? icons : nil;
    if ([icons isKindOfClass:NSDictionary.class]) for (NSString *size in @[@"32", @"48", @"38", @"64", @"128", @"16"]) if (icons[size]) { path = icons[size]; break; }
    if (!path) return nil;
    NSImage *im = [[NSImage alloc] initWithContentsOfFile:[e.dir stringByAppendingPathComponent:path]];
    im.size = NSMakeSize(18, 18);
    return im;
}
- (NSString *)nameForID:(NSString *)ident { return _exts[ident.lowercaseString].name; }
- (NSImage *)iconForID:(NSString *)ident { return [self iconFor:_exts[ident.lowercaseString]]; }

#pragma mark Managing extensions (Settings ▸ Extensions)

- (NSArray<NSDictionary *> *)allExtensionInfo {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *src in @[_exts, _disabled]) for (FExt *e in src.allValues)
        [out addObject:@{@"ident": e.ident, @"name": e.name ?: e.ident, @"version": e.manifest[@"version"] ?: @"", @"dir": e.dir,
                         @"enabled": @(src == _exts), @"icon": [self iconFor:e] ?: [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:nil]}];
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] compare:b[@"name"]]; }];
}
- (void)setExtension:(NSString *)ident enabled:(BOOL)on {
    NSMutableArray *off = [[Defaults() arrayForKey:kExtDisabled] ?: @[] mutableCopy];
    if (on) [off removeObject:ident]; else if (![off containsObject:ident]) [off addObject:ident];
    [Defaults() setObject:off forKey:kExtDisabled];
}
- (void)removeExtension:(NSString *)ident {
    FExt *e = _exts[ident] ?: _disabled[ident]; if (!e) return;
    [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:e.dir] resultingItemURL:nil error:nil];
    [_disabled removeObjectForKey:ident];
}

// Install from a Chrome Web Store link (or a bare extension ID): download the CRX, keep its official ID
// (the public key goes into manifest.json, so sites that talk to the extension still recognise it), unpack.
- (void)installFromWebStore:(NSString *)input done:(void (^)(NSString *name, NSString *error))done {
    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"[a-p]{32}" options:0 error:nil];
    NSTextCheckingResult *m = [rx firstMatchInString:input ?: @"" options:0 range:NSMakeRange(0, input.length)];
    if (!m) { done(nil, @"That doesn't look like a Chrome Web Store link."); return; }
    NSString *ident = [input substringWithRange:m.range];
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0.0.0&acceptformat=crx2,crx3&x=id%%3D%@%%26installsource%%3Dondemand%%26uc", ident]];
    [[NSURLSession.sharedSession dataTaskWithURL:u completionHandler:^(NSData *crx, NSURLResponse *r, NSError *err) {
        NSString *problem = nil, *name = nil;
        NSData *zip = nil, *key = nil;
        const uint8_t *b = crx.bytes;
        if (!crx || crx.length < 16 || memcmp(b, "Cr24", 4) != 0) problem = err.localizedDescription ?: @"The Web Store didn't send an extension.";
        else {
            uint32_t ver = OSReadLittleInt32(b, 4);
            if (ver == 2) {
                uint32_t kl = OSReadLittleInt32(b, 8), sl = OSReadLittleInt32(b, 12);
                if (16 + kl + sl <= crx.length) { key = [crx subdataWithRange:NSMakeRange(16, kl)]; zip = [crx subdataWithRange:NSMakeRange(16 + kl + sl, crx.length - 16 - kl - sl)]; }
            } else {
                uint32_t hl = OSReadLittleInt32(b, 8);
                if (12 + hl <= crx.length) {
                    zip = [crx subdataWithRange:NSMakeRange(12 + hl, crx.length - 12 - hl)];
                    // CRX3 header is protobuf: fields 2/3 hold {1: public key, 2: signature}; pick the key whose ID matches
                    const uint8_t *h = b + 12; size_t n = hl, i = 0;
                    uint64_t (^varint)(size_t *) = ^uint64_t(size_t *p) { uint64_t v = 0; int s = 0; while (*p < n) { uint8_t c = h[(*p)++]; v |= (uint64_t)(c & 127) << s; s += 7; if (!(c & 128)) break; } return v; };
                    while (i < n && !key) {
                        uint64_t tag = varint(&i); uint64_t f = tag >> 3, wt = tag & 7;
                        if (wt != 2) { if (wt == 0) varint(&i); else break; continue; }
                        uint64_t len = varint(&i); size_t end = i + (size_t)len; if (end > n) break;
                        if (f == 2 || f == 3) {
                            size_t j = i;
                            while (j < end) {
                                size_t jj = j; uint64_t t2 = 0; int s2 = 0; while (jj < end) { uint8_t c = h[jj++]; t2 |= (uint64_t)(c & 127) << s2; s2 += 7; if (!(c & 128)) break; }
                                uint64_t l2 = 0; s2 = 0; while (jj < end) { uint8_t c = h[jj++]; l2 |= (uint64_t)(c & 127) << s2; s2 += 7; if (!(c & 128)) break; }
                                if ((t2 >> 3) == 1 && jj + l2 <= end) {
                                    NSData *cand = [NSData dataWithBytes:h + jj length:(NSUInteger)l2];
                                    if ([ExtIDFromKey([cand base64EncodedStringWithOptions:0]) isEqualToString:ident]) key = cand;
                                }
                                j = jj + (size_t)l2;
                            }
                        }
                        i = end;
                    }
                }
            }
            if (!zip.length) problem = @"The extension file was damaged.";
        }
        if (!problem) {
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.zip", ident]];
            [zip writeToFile:tmp atomically:YES];
            NSString *dest = [ExtRoot() stringByAppendingPathComponent:ident];
            [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
            NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/ditto" arguments:@[@"-x", @"-k", tmp, dest]];
            [t waitUntilExit];
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            [NSFileManager.defaultManager removeItemAtPath:[dest stringByAppendingPathComponent:@"_metadata"] error:nil];
            NSMutableDictionary *mf = JSONFile([dest stringByAppendingPathComponent:@"manifest.json"]);
            if (![mf isKindOfClass:NSDictionary.class]) problem = @"The extension has no manifest.";
            else {
                if (key) mf[@"key"] = [key base64EncodedStringWithOptions:0];
                [[NSJSONSerialization dataWithJSONObject:mf options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[dest stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
                name = mf[@"name"];
                if ([name hasPrefix:@"__MSG_"]) {
                    NSString *loc = mf[@"default_locale"] ?: @"en";
                    NSDictionary *msgs = JSONFile([NSString stringWithFormat:@"%@/_locales/%@/messages.json", dest, loc]);
                    NSString *k = [name substringWithRange:NSMakeRange(6, name.length - 8)];
                    for (NSString *mk in msgs) if ([mk caseInsensitiveCompare:k] == NSOrderedSame) name = msgs[mk][@"message"];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(name, problem); });
    }] resume];
}

#pragma mark Test harness hooks

- (void)evalIn:(NSString *)where code:(NSString *)code {
    FExt *e = self.extensions.firstObject;
    if ([code hasPrefix:@"@"]) {   // "@<extension id> code": a particular extension
        NSRange sp = [code rangeOfString:@" "];
        if (sp.location != NSNotFound) { FExt *x = _exts[[code substringWithRange:NSMakeRange(1, sp.location - 1)]]; if (x) e = x; code = [code substringFromIndex:sp.location + 1]; }
    }
    WKWebView *v = [where isEqualToString:@"bg"] ? e.background : (WKWebView *)_popover.contentViewController.view;
    if (![v isKindOfClass:WKWebView.class]) { CtlOut([where stringByAppendingString:@" not open"]); return; }
    [v callAsyncJavaScript:[NSString stringWithFormat:@"const r = await (%@); return typeof r === 'object' ? JSON.stringify(r) : String(r);", code]
                 arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id r, NSError *err) {
        NSString *out = err ? [@"ERR " stringByAppendingString:(err.userInfo[@"WKJavaScriptExceptionMessage"] ?: err.localizedDescription)] : [r description];
        CtlOut([NSString stringWithFormat:@"%@js %@", where, out.length > 3000 ? [out substringToIndex:3000] : out]);
    }];
}

#pragma mark Popup (the toolbar button's page)

- (BOOL)openOptions:(FExt *)e {
    id ui = e.manifest[@"options_ui"];
    NSString *opt = [ui isKindOfClass:NSDictionary.class] && [ui[@"page"] isKindOfClass:NSString.class] ? ui[@"page"] : [e.manifest[@"options_page"] isKindOfClass:NSString.class] ? e.manifest[@"options_page"] : nil;
    if (!opt) return NO;
    NSString *url = [NSString stringWithFormat:@"chrome-extension://%@/%@", e.ident, [opt hasPrefix:@"/"] ? [opt substringFromIndex:1] : opt];
    VWindow *w = NormalWin();
    for (VTab *t in w.tabs) if ([t.url hasPrefix:url]) { [w selectTab:t]; return YES; }   // already open: switch to it
    [w newTab:[NSURL URLWithString:url] select:YES];
    return YES;
}
- (BOOL)openOptionsForID:(NSString *)ident { FExt *e = _exts[ident ?: @""]; return e ? [self openOptions:e] : NO; }
- (BOOL)hasOptionsForID:(NSString *)ident {
    FExt *e = _exts[ident ?: @""]; id ui = e.manifest[@"options_ui"];
    return ([ui isKindOfClass:NSDictionary.class] && ui[@"page"]) || [e.manifest[@"options_page"] isKindOfClass:NSString.class];
}

// Popups take the size of their content (Chrome: between 25×25 and 800×600). The page is measured at its natural
// size: the root laid out at max-content, so an element that fills the width doesn't fill the old window instead.
static NSString *const kPopupMeasureJS = @"(()=>{const d=document.documentElement,b=document.body;if(!b)return null;"
    "const sw=d.style.width,sh=d.style.height,bw=b.style.width,bh=b.style.height;"
    "d.style.width='max-content';d.style.height='max-content';b.style.height='auto';"
    "const r=d.getBoundingClientRect();let w=Math.ceil(r.width),h=Math.ceil(Math.max(r.height,b.scrollHeight));"
    "d.style.width=sw;d.style.height=sh;b.style.width=bw;b.style.height=bh;return[w,h]})()";
- (void)fitPopup:(WKWebView *)v {
    if (!_popover || _popover.contentViewController.view != v) return;
    [v evaluateJavaScript:kPopupMeasureJS completionHandler:^(id r, NSError *err) {
        if (![r isKindOfClass:NSArray.class] || [r count] != 2 || self->_popover.contentViewController.view != v) return;
        CGFloat w = MIN(800, MAX(25, [r[0] doubleValue])), h = MIN(600, MAX(25, [r[1] doubleValue]));
        if (fabs(w - self->_popover.contentSize.width) > 1 || fabs(h - self->_popover.contentSize.height) > 1) self->_popover.contentSize = NSMakeSize(w, h);
    }];
}
- (void)webView:(WKWebView *)v didFinishNavigation:(WKNavigation *)n {
    [self fitPopup:v];
    // pages that build themselves after loading settle a moment later
    for (NSNumber *ms in @[@150, @500, @1200]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms.longLongValue * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self fitPopup:v]; });
}

- (void)openPopup:(FExt *)e from:(NSView *)anchor {
    if (!e) e = self.extensions.firstObject;
    NSDictionary *action = e.manifest[@"action"] ?: e.manifest[@"browser_action"];
    NSString *page = [action[@"default_popup"] isKindOfClass:NSString.class] ? action[@"default_popup"] : nil;
    if (!page) {   // like Chrome: tell the extension it was clicked; if it doesn't listen, open its options
        VTab *cur = NormalWin().current;
        [self toBackground:e body:@"return globalThis.__flintActionClicked ? __flintActionClicked(tab) : false" args:@{@"tab": TabInfo(cur) ?: @{}} done:^(id r, NSError *err) {
            if ([r boolValue]) return;
            if (![self openOptions:e]) [gWin showToast:[NSString stringWithFormat:@"%@ has no popup or options", e.name]];
        }];
        return;
    }
    [_popover close];
    WKWebView *v = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 380, 600) configuration:FlintConfig()];
    if (@available(macOS 13.3, *)) v.inspectable = YES;
    @try { [v setValue:@NO forKey:@"drawsBackground"]; } @catch (NSException *x) {}
    v.navigationDelegate = self;   // sized to its content once it has loaded, as Chrome does
    [v loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"chrome-extension://%@/%@", e.ident, page]]]];
    NSViewController *vc = [NSViewController new]; vc.view = v;
    _popover = [NSPopover new];
    _popover.contentViewController = vc;
    _popover.contentSize = NSMakeSize(380, 600);
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.appearance = ThemeAppearance();
    NSView *at = anchor ?: [gWin.toolbar extensionButtonFor:e.ident] ?: gWin.toolbar.menuBtn;
    [_popover showRelativeToRect:at.bounds ofView:at preferredEdge:NSRectEdgeMaxY];
}

@end

#pragma mark - Flint's own pages (flint://history, flint://bookmarks)

// Built-in pages are plain HTML files (Resources/pages, or pages/ beside Flint.app while developing),
// served on the flint: scheme with the current theme's colours filled in. They talk to Flint through
// flintInternal, which answers only main frames whose origin is flint: — websites, extensions and
// frames embedded in other pages can't reach it.

static NSString *CSSColor(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: c;
    return [NSString stringWithFormat:@"rgba(%d,%d,%d,%.3f)", (int)lround(s.redComponent * 255), (int)lround(s.greenComponent * 255), (int)lround(s.blueComponent * 255), s.alphaComponent];
}

// Flint's own pages share the window's colours and its shape language: struck shards, the spark, compressed headings.
static NSString *ThemeCSS(void) {
    NSString *vars = [NSString stringWithFormat:@":root{color-scheme:%@;--bg:%@;--card:%@;--pill:%@;--text:%@;--dim:%@;--faint:%@;--line:%@;--hover:%@;--active:%@;--accent:%@;--border:%@;--toast:%@;--onaccent:%@;--ember:%@}",
            ThemeIsLight() ? @"light" : @"dark", CSSColor(vContentBg), CSSColor(vCard), CSSColor(vPill), CSSColor(vText), CSSColor(vDim), CSSColor(vFaint),
            CSSColor(vSep), CSSColor(vHover), CSSColor(vActive), CSSColor(vAccent), CSSColor(vBorder), CSSColor(vToast), CSSColor(vBadgeText), CSSColor(vEmber)];
    return [vars stringByAppendingString:@" .btn,.search input,.field input,.field select,.acts a,.bar button,.bar a,.selbar{border-radius:8px!important}"
        ".list,.menu,dialog,.pop{border-radius:12px!important}"
        ".search input:focus,.field input:focus,.field select:focus{box-shadow:0 0 0 3px color-mix(in srgb,var(--text) 10%,transparent)!important;border-color:var(--faint)!important}"
        ".btn.primary,.btn.danger,.acts a.primary{background:var(--text)!important;color:var(--bg)!important;border-color:transparent!important}"
        ".menu button:hover{background:var(--active)!important;color:var(--text)!important}"
        "mark{background:color-mix(in srgb,var(--text) 18%,transparent)!important;color:inherit!important}"
        "h1{font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;font-weight:650;letter-spacing:-.022em}"
        "h2{letter-spacing:.02em}"
        ".prog{background:var(--dim)!important}.search svg{z-index:2}"];
}

static NSString *InternalPagePath(NSString *name) {
    if (![[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz-"] isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:name]]) return nil;
    NSString *file = [name stringByAppendingPathExtension:@"html"];
    NSString *res = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"pages"] stringByAppendingPathComponent:file];
    return [NSFileManager.defaultManager fileExistsAtPath:res] ? res : nil;
}


#pragma mark Bookmarks: validation and imports from other browsers

// A tree sent by the bookmark manager is rebuilt from scratch: only names, URLs and folders survive.
static NSMutableDictionary *CleanNode(id n, int depth) {
    if (depth > 40 || ![n isKindOfClass:NSDictionary.class]) return nil;
    NSString *name = [n[@"name"] isKindOfClass:NSString.class] ? n[@"name"] : @"";
    if (name.length > 1000) name = [name substringToIndex:1000];
    if ([n[@"children"] isKindOfClass:NSArray.class]) {
        NSMutableArray *kids = [NSMutableArray array];
        for (id c in n[@"children"]) { NSMutableDictionary *k = CleanNode(c, depth + 1); if (k) [kids addObject:k]; }
        return [NSMutableDictionary dictionaryWithDictionary:@{@"name": name.length ? name : @"Folder", @"children": kids}];
    }
    NSString *url = [n[@"url"] isKindOfClass:NSString.class] ? Trim(n[@"url"]) : nil;
    NSURL *u = url.length && url.length < 8192 ? [NSURL URLWithString:url] : nil;
    if (!u.scheme.length) return nil;
    return [NSMutableDictionary dictionaryWithDictionary:@{@"name": name, @"url": url}];
}

static NSString *AppSupport(NSString *rel) { return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"] stringByAppendingPathComponent:rel]; }

// Chromium-family browsers keep bookmarks in the same JSON format.
static NSArray<NSArray<NSString *> *> *ChromiumSources(void) {
    return @[@[@"chrome", @"Google Chrome", @"Google/Chrome"], @[@"helium", @"Helium", @"net.imput.helium"], @[@"brave", @"Brave", @"BraveSoftware/Brave-Browser"],
             @[@"edge", @"Microsoft Edge", @"Microsoft Edge"], @[@"vivaldi", @"Vivaldi", @"Vivaldi"], @[@"arc", @"Arc", @"Arc/User Data"], @[@"chromium", @"Chromium", @"Chromium"]];
}
static NSString *ChromiumBookmarksFile(NSString *rel) {
    for (NSString *p in @[@"Default", @"Profile 1", @"Profile 2", @"Profile 3"]) {
        NSString *f = [[AppSupport(rel) stringByAppendingPathComponent:p] stringByAppendingPathComponent:@"Bookmarks"];
        if ([NSFileManager.defaultManager fileExistsAtPath:f]) return f;
    }
    return nil;
}
static NSString *GeckoPlaces(NSString *rel) {
    NSString *dir = [AppSupport(rel) stringByAppendingPathComponent:@"Profiles"];
    NSString *best = nil; NSDate *bestDate = nil;
    for (NSString *p in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        NSString *f = [[dir stringByAppendingPathComponent:p] stringByAppendingPathComponent:@"places.sqlite"];
        NSDate *d = [NSFileManager.defaultManager attributesOfItemAtPath:f error:nil].fileModificationDate;
        if (d && (!bestDate || [d compare:bestDate] == NSOrderedDescending)) { best = f; bestDate = d; }
    }
    return best;
}
static NSArray<NSDictionary *> *ImportSources(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *s in ChromiumSources()) if (ChromiumBookmarksFile(s[2])) [out addObject:@{@"id": s[0], @"name": s[1]}];
    if (GeckoPlaces(@"Firefox")) [out addObject:@{@"id": @"firefox", @"name": @"Firefox"}];
    if (GeckoPlaces(@"zen")) [out addObject:@{@"id": @"zen", @"name": @"Zen"}];
    [out addObject:@{@"id": @"safari", @"name": @"Safari"}];
    return out;
}

static NSMutableDictionary *SafariNode(NSDictionary *n) {
    NSString *type = n[@"WebBookmarkType"];
    if ([type isEqualToString:@"WebBookmarkTypeList"]) {
        NSString *title = n[@"Title"] ?: @"Folder";
        if ([title isEqualToString:@"com.apple.ReadingList"]) return nil;
        if ([title isEqualToString:@"BookmarksBar"]) title = @"Favourites";
        if ([title isEqualToString:@"BookmarksMenu"]) title = @"Bookmarks Menu";
        NSMutableArray *kids = [NSMutableArray array];
        for (NSDictionary *c in n[@"Children"]) { NSMutableDictionary *k = SafariNode(c); if (k) [kids addObject:k]; }
        return [NSMutableDictionary dictionaryWithDictionary:@{@"name": title, @"children": kids}];
    }
    if ([type isEqualToString:@"WebBookmarkTypeLeaf"] && [n[@"URLString"] isKindOfClass:NSString.class])
        return [NSMutableDictionary dictionaryWithDictionary:@{@"name": n[@"URIDictionary"][@"title"] ?: @"", @"url": n[@"URLString"]}];
    return nil;
}

static NSArray *GeckoTree(NSString *places, NSString **err) {
    NSString *tmp = SupportFile(@"import-places.sqlite");
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *sfx in @[@"", @"-wal"]) {
        [fm removeItemAtPath:[tmp stringByAppendingString:sfx] error:nil];
        NSString *src = [places stringByAppendingString:sfx];
        if ([fm fileExistsAtPath:src]) [fm copyItemAtPath:src toPath:[tmp stringByAppendingString:sfx] error:nil];
    }
    sqlite3 *db = NULL;
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *byId = [NSMutableDictionary dictionary];
    NSMutableArray *rows = [NSMutableArray array];
    if (sqlite3_open_v2(tmp.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_stmt *st = NULL;
        const char *sql = "SELECT b.id, b.parent, b.type, b.title, p.url, b.guid FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk = p.id ORDER BY b.parent, b.position";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                const char *ti = (const char *)sqlite3_column_text(st, 3), *u = (const char *)sqlite3_column_text(st, 4), *g = (const char *)sqlite3_column_text(st, 5);
                [rows addObject:@{@"id": @(sqlite3_column_int64(st, 0)), @"parent": @(sqlite3_column_int64(st, 1)), @"type": @(sqlite3_column_int(st, 2)),
                                  @"title": ti ? @(ti) : @"", @"url": u ? @(u) : @"", @"guid": g ? @(g) : @""}];
            }
            sqlite3_finalize(st);
        } else if (err) *err = @"Couldn't read the bookmarks database.";
        sqlite3_close(db);
    } else if (err) *err = @"Couldn't open the bookmarks database.";
    for (NSString *sfx in @[@"", @"-wal", @"-shm"]) [fm removeItemAtPath:[tmp stringByAppendingString:sfx] error:nil];
    for (NSDictionary *r in rows) {
        if ([r[@"type"] intValue] == 2) byId[r[@"id"]] = [NSMutableDictionary dictionaryWithDictionary:@{@"name": r[@"title"], @"children": [NSMutableArray array], @"guid": r[@"guid"]}];
        else if ([r[@"type"] intValue] == 1 && [r[@"url"] length] && ![r[@"url"] hasPrefix:@"place:"]) byId[r[@"id"]] = [NSMutableDictionary dictionaryWithDictionary:@{@"name": r[@"title"], @"url": r[@"url"]}];
    }
    for (NSDictionary *r in rows) { NSMutableDictionary *n = byId[r[@"id"]], *p = byId[r[@"parent"]]; if (n && p) [p[@"children"] addObject:n]; }
    NSDictionary *names = @{@"toolbar_____": @"Bookmarks Toolbar", @"menu________": @"Bookmarks Menu", @"unfiled_____": @"Other Bookmarks", @"mobile______": @"Mobile Bookmarks"};
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *g in @[@"toolbar_____", @"menu________", @"unfiled_____", @"mobile______"]) {
        for (NSMutableDictionary *n in byId.allValues) if ([n[@"guid"] isEqualToString:g] && [n[@"children"] count]) {
            n[@"name"] = names[g]; [out addObject:n];
        }
    }
    return out;   // guid keys are dropped by CleanNode on the way back in
}

static NSArray *ImportTree(NSString *source, NSString **err) {
    for (NSArray *s in ChromiumSources()) if ([s[0] isEqualToString:source]) {
        NSData *d = [NSData dataWithContentsOfFile:ChromiumBookmarksFile(s[2]) ?: @""];
        NSDictionary *root = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (![root isKindOfClass:NSDictionary.class]) { *err = [NSString stringWithFormat:@"Couldn't read %@'s bookmarks.", s[1]]; return nil; }
        NSMutableArray *out = [NSMutableArray array];
        NSDictionary *names = @{@"bookmark_bar": @"Bookmarks Bar", @"other": @"Other Bookmarks", @"synced": @"Mobile Bookmarks"};
        for (NSString *k in @[@"bookmark_bar", @"other", @"synced"]) {
            NSMutableDictionary *n = ConvertChromeNode(root[@"roots"][k] ?: @{});
            if ([n[@"children"] count]) { n[@"name"] = names[k]; [out addObject:n]; }
        }
        return out;
    }
    if ([source isEqualToString:@"firefox"] || [source isEqualToString:@"zen"]) {
        NSString *places = GeckoPlaces([source isEqualToString:@"zen"] ? @"zen" : @"Firefox");
        if (!places) { *err = @"No profile found."; return nil; }
        return GeckoTree(places, err);
    }
    if ([source isEqualToString:@"safari"]) {
        NSString *f = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Safari/Bookmarks.plist"];
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:f];
        if (!root) { *err = @"macOS keeps Safari's bookmarks private. In Safari choose File › Export › Bookmarks…, then use “Import from HTML file…” here."; return nil; }
        NSMutableDictionary *n = SafariNode(root);
        return n[@"children"] ?: @[];
    }
    *err = @"Unknown browser.";
    return nil;
}


static NSMutableDictionary<NSString *, NSDictionary *> *gReader;   // reader articles, by one-time id (in memory only)

@interface VInternal : NSObject <WKURLSchemeHandler, WKScriptMessageHandlerWithReply>
+ (instancetype)shared;
@end

@implementation VInternal

+ (instancetype)shared { static VInternal *v; static dispatch_once_t once; dispatch_once(&once, ^{ v = [VInternal new]; }); return v; }

static void Respond(id<WKURLSchemeTask> task, NSInteger status, NSString *type, NSData *body, NSDictionary *extra) {
    NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:@{@"Content-Type": type, @"Cache-Control": @"no-store"}];
    [h addEntriesFromDictionary:extra ?: @{}];
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:h];
    @try { [task didReceiveResponse:r]; [task didReceiveData:body ?: [NSData data]]; [task didFinish]; } @catch (NSException *e) {}
}

- (void)webView:(WKWebView *)w startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *u = task.request.URL;
    NSString *host = u.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"favicon"]) {
        NSString *page = nil;
        for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO].queryItems) if ([q.name isEqualToString:@"u"]) page = q.value;
        NSString *k = page ? IconKey(page) : nil;
        NSData *png = k ? [NSData dataWithContentsOfFile:[[IconDir() stringByAppendingPathComponent:k] stringByAppendingPathExtension:@"png"]] : nil;
        Respond(task, png ? 200 : 404, png ? @"image/png" : @"text/plain", png, @{@"Cache-Control": @"max-age=600"});
        return;
    }
    if ([host isEqualToString:@"dlicon"]) {   // the Mac's own icon for a file type, for the download manager
        NSString *ext = [u.lastPathComponent stringByRemovingPercentEncoding] ?: @"";
        static NSCache *cache; if (!cache) cache = [NSCache new];
        NSData *png = [cache objectForKey:ext];
        if (!png) {
            UTType *t = [UTType typeWithFilenameExtension:ext] ?: UTTypeData;
            NSImage *im = [NSWorkspace.sharedWorkspace iconForContentType:t];
            NSImage *sized = [NSImage imageWithSize:NSMakeSize(64, 64) flipped:NO drawingHandler:^BOOL(NSRect r) { [im drawInRect:r]; return YES; }];
            CGImageRef cg = [sized CGImageForProposedRect:NULL context:nil hints:nil];
            png = cg ? [[[NSBitmapImageRep alloc] initWithCGImage:cg] representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
            if (png) [cache setObject:png forKey:ext];
        }
        Respond(task, png ? 200 : 404, png ? @"image/png" : @"text/plain", png, @{@"Cache-Control": @"max-age=3600"});
        return;
    }
    // pages only open as a whole tab, never framed inside a website
    NSURL *top = task.request.mainDocumentURL;
    if (top && ![top.scheme isEqualToString:@"flint"]) { Respond(task, 403, @"text/plain", nil, nil); return; }
    NSString *path = InternalPagePath(host);
    NSString *html = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!html) {
        html = [NSString stringWithFormat:@"<!doctype html><meta charset=utf-8><title>Not found</title><style>/*THEME*/html{background:var(--bg);color:var(--dim);font:15px -apple-system,system-ui;display:grid;place-items:center;height:100%%}</style><p>Flint has no page called “%@”.</p>",
                [[host stringByReplacingOccurrencesOfString:@"<" withString:@""] stringByReplacingOccurrencesOfString:@"&" withString:@""]];
    }
    // scripts run only with this response's nonce: markup that slips into a page (a reader article, a bookmark name) can't run code
    uint8_t rnd[18]; arc4random_buf(rnd, sizeof rnd);
    NSString *nonce = [[NSData dataWithBytes:rnd length:sizeof rnd] base64EncodedStringWithOptions:0];
    html = [html stringByReplacingOccurrencesOfString:@"/*THEME*/" withString:ThemeCSS()];
    html = [html stringByReplacingOccurrencesOfString:@"{{NONCE}}" withString:nonce];
    NSString *img = [host isEqualToString:@"reader"] ? @"flint: data: https: http:" : @"flint: data:";
    Respond(task, path ? 200 : 404, @"text/html; charset=utf-8", [html dataUsingEncoding:NSUTF8StringEncoding],
            @{@"Content-Security-Policy": [NSString stringWithFormat:@"default-src 'none'; img-src %@; media-src https:; style-src 'unsafe-inline'; script-src 'nonce-%@'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'", img, nonce]});
}

- (void)webView:(WKWebView *)w stopURLSchemeTask:(id<WKURLSchemeTask>)task {}

// The download manager page (flint://downloads): a list it polls, and the controls it calls.
static NSString *DLCategory(NSString *ext) {
    ext = ext.lowercaseString;
    NSDictionary *m = @{@"video": @[@"mp4", @"mkv", @"mov", @"avi", @"webm", @"m4v", @"flv", @"wmv", @"mpg", @"mpeg", @"ts"],
                        @"audio": @[@"mp3", @"m4a", @"aac", @"flac", @"wav", @"ogg", @"opus", @"aiff", @"wma"],
                        @"archive": @[@"zip", @"rar", @"7z", @"tar", @"gz", @"bz2", @"xz", @"tgz", @"zst", @"lz"],
                        @"doc": @[@"pdf", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx", @"txt", @"rtf", @"epub", @"pages", @"numbers", @"key", @"csv", @"md", @"odt"],
                        @"program": @[@"dmg", @"pkg", @"app", @"exe", @"msi", @"iso", @"deb", @"rpm", @"apk", @"appimage", @"jar"],
                        @"image": @[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"svg", @"bmp", @"tiff", @"avif", @"ico"]};
    for (NSString *k in m) if ([m[k] containsObject:ext]) return k;
    return @"other";
}
static NSDictionary *DLInfo(VDownload *x) {
    NSString *ext = x.name.pathExtension.length ? x.name.pathExtension : @"bin";
    NSMutableDictionary *d = [@{@"id": x.ident ?: @"", @"name": x.name ?: @"", @"url": x.url ?: @"", @"host": HostOf([NSURL URLWithString:x.url ?: @""]) ?: @"",
        @"state": x.state ?: @"failed", @"kind": x.kind ?: @"webkit", @"got": @(x.received), @"total": @(x.total), @"speed": @((int64_t)x.speed), @"peak": @((int64_t)x.peak),
        @"t": @(x.started), @"end": @(x.ended), @"conns": @(x.conns), @"res": @(x.resumable), @"path": x.path ?: @"", @"ext": ext.lowercaseString,
        @"cat": DLCategory(ext), @"exists": @([x.state isEqual:@"done"] && [NSFileManager.defaultManager fileExistsAtPath:x.path ?: @""])} mutableCopy];
    if (x.error) d[@"err"] = x.error;
    if ([x.kind isEqual:@"accel"] && ![x.state isEqual:@"done"] && x.total > 0 && x.segs.count) {
        NSMutableArray *segs = [NSMutableArray array];
        NSArray *live = x.tasks.allKeys ?: @[];
        NSUInteger i = 0;
        for (NSDictionary *g in x.segs.copy) { if (segs.count < 48) [segs addObject:@[g[@"s"] ?: @0, g[@"e"] ?: @0, g[@"g"] ?: @0, @([live containsObject:@(i)])]]; i++; }
        d[@"segs"] = segs;
    }
    return d;
}
static void DownloadOp(NSString *op, NSDictionary *b, VWindow *win, void (^reply)(id, NSString *)) {
    VDownloads *D = VDownloads.shared; FAccel *A = FAccel.shared;
    VDownload *x = [b[@"id"] isKindOfClass:NSString.class] ? [D byId:b[@"id"]] : nil;
    if ([op isEqualToString:@"dl.list"]) {
        NSMutableArray *out = [NSMutableArray array]; NSInteger running = 0;
        for (VDownload *it in D.items.copy) { if (!it.ident) it.ident = NSUUID.UUID.UUIDString; [out addObject:DLInfo(it)]; if ([it.state isEqual:@"running"]) running++; }
        int64_t speed = A.currentSpeed;
        for (VDownload *it in D.items.copy) if ([it.kind isEqual:@"webkit"] && [it.state isEqual:@"running"]) speed += (int64_t)it.speed;
        reply(@{@"items": out, @"speed": @(speed), @"running": @(running),
                @"settings": @{@"accel": @([Defaults() boolForKey:kDLAccel]), @"conns": @([Defaults() integerForKey:kDLConns]), @"active": @([Defaults() integerForKey:kDLActive]),
                               @"limit": @([Defaults() integerForKey:kDLLimit]), @"ask": @([Defaults() boolForKey:kAskDownload]), @"folder": win.downloadFolder.path ?: @""}}, nil);
        return;
    }
    if ([op isEqualToString:@"dl.pause"]) { if (x) [A pause:x]; reply(@YES, nil); return; }
    if ([op isEqualToString:@"dl.resume"] || [op isEqualToString:@"dl.retry"]) {
        if (x && [x.kind isEqual:@"webkit"] && x.resume && x.view) { [D.items removeObject:x]; [x.view resumeDownloadFromResumeData:x.resume completionHandler:^(WKDownload *d) { d.delegate = (id<WKDownloadDelegate>)x.view.navigationDelegate; }]; }
        else if (x && [x.state isEqual:@"cancelled"]) { [D.items removeObject:x]; [A downloadURL:[NSURL URLWithString:x.url] name:x.name referer:x.referer view:win.current.web.web private:NO]; }
        else if (x) [A resume:x];
        [D save]; reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"dl.cancel"]) { if (x) [A cancel:x]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [D save]; }); reply(@YES, nil); return; }
    if ([op isEqualToString:@"dl.remove"]) {
        if (x) { if ([@[@"running", @"queued"] containsObject:x.state ?: @""]) [A cancel:x]; [D.items removeObject:x]; [D save]; [D changed]; }
        reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"dl.trash"]) {   // the file goes to the Trash (recoverable), and the entry leaves the list
        if (x.path && [NSFileManager.defaultManager fileExistsAtPath:x.path]) [NSWorkspace.sharedWorkspace recycleURLs:@[[NSURL fileURLWithPath:x.path]] completionHandler:nil];
        if (x) { [D.items removeObject:x]; [D save]; [D changed]; }
        reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"dl.open"]) { if (x.path) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:x.path]]; reply(@YES, nil); return; }
    if ([op isEqualToString:@"dl.reveal"]) {
        NSString *p = [x.state isEqual:@"done"] ? x.path : x.partPath ?: x.path;
        if (p && [NSFileManager.defaultManager fileExistsAtPath:p]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:p]]];
        else [NSWorkspace.sharedWorkspace openURL:win.downloadFolder];
        reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"dl.copy"]) { if (x.url) { [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:x.url forType:NSPasteboardTypeString]; [win showToast:@"Link copied"]; } reply(@YES, nil); return; }
    if ([op isEqualToString:@"dl.add"]) {
        NSURL *u = [b[@"url"] isKindOfClass:NSString.class] ? URLFromInput(Trim(b[@"url"])) : nil;
        if (![@[@"http", @"https"] containsObject:u.scheme.lowercaseString ?: @""]) { reply(@NO, nil); return; }
        [A downloadURL:u name:nil referer:nil view:win.current.web.web ?: nil private:win.isPrivate];
        reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"dl.pauseAll"]) { [A pauseAll]; reply(@YES, nil); return; }
    if ([op isEqualToString:@"dl.resumeAll"]) { [A resumeAll]; reply(@YES, nil); return; }
    if ([op isEqualToString:@"dl.openFolder"]) { [NSWorkspace.sharedWorkspace openURL:win.downloadFolder]; reply(@YES, nil); return; }
    if ([op isEqualToString:@"dl.chooseFolder"]) { [win showSettingsSection:@"downloads"]; reply(@YES, nil); return; }
    if ([op isEqualToString:@"dl.set"]) {
        NSString *k = b[@"key"]; id v = b[@"value"];
        if ([k isEqual:@"accel"]) [Defaults() setBool:[v boolValue] forKey:kDLAccel];
        else if ([k isEqual:@"ask"]) [Defaults() setBool:[v boolValue] forKey:kAskDownload];
        else if ([k isEqual:@"conns"]) [Defaults() setInteger:MAX(1, MIN(16, [v integerValue])) forKey:kDLConns];
        else if ([k isEqual:@"active"]) [Defaults() setInteger:MAX(1, MIN(8, [v integerValue])) forKey:kDLActive];
        else if ([k isEqual:@"limit"]) [Defaults() setInteger:MAX(0, [v integerValue]) forKey:kDLLimit];
        reply(@YES, nil); return;
    }
    reply(nil, @"unknown");
}

static NSURL *WebURL(id s) {
    NSURL *u = [s isKindOfClass:NSString.class] ? [NSURL URLWithString:s] : nil;
    return [@[@"http", @"https", @"flint", @"file"] containsObject:u.scheme.lowercaseString ?: @""] ? u : nil;
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)m replyHandler:(void (^)(id, NSString *))reply {
    if (!m.frameInfo.isMainFrame || ![m.frameInfo.securityOrigin.protocol isEqualToString:@"flint"] || ![m.body isKindOfClass:NSDictionary.class]) { reply(nil, @"denied"); return; }
    NSDictionary *b = m.body;
    VWindow *win = WinOfWeb(m.webView) ?: gWin;
    NSString *op = [b[@"op"] isKindOfClass:NSString.class] ? b[@"op"] : @"";

    if ([op hasPrefix:@"dl."]) { DownloadOp(op, b, win, reply); return; }
    if ([op hasPrefix:@"settings."]) { SettingsOp(op, b, win, reply); return; }
    if ([op isEqualToString:@"history.list"]) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *e in [VHistory.shared all]) [out addObject:@{@"u": e[@"u"] ?: @"", @"ti": e[@"ti"] ?: @"", @"t": e[@"t"] ?: @0, @"c": e[@"c"] ?: @1}];
        reply(out, nil); return;
    }
    if ([op isEqualToString:@"history.remove"]) {
        NSArray *urls = [b[@"urls"] isKindOfClass:NSArray.class] ? b[@"urls"] : @[];
        [VHistory.shared removeURLs:urls]; reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"history.removeHost"]) {
        NSString *h = [b[@"host"] isKindOfClass:NSString.class] ? b[@"host"] : nil;
        [VHistory.shared removeHost:h]; reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"history.clear"]) {
        NSString *range = [b[@"range"] isKindOfClass:NSString.class] ? b[@"range"] : @"hour";
        NSDictionary *names = @{@"hour": @"the last hour", @"today": @"today", @"week": @"the last 7 days", @"all": @"all time"};
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSTimeInterval since = [range isEqualToString:@"hour"] ? now - 3600 : [range isEqualToString:@"today"] ? [NSCalendar.currentCalendar startOfDayForDate:NSDate.date].timeIntervalSince1970
                             : [range isEqualToString:@"week"] ? now - 7 * 86400 : 0;
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Clear history from %@?", names[range] ?: @"the last hour"];
        a.informativeText = @"Pages you visited in this period are removed from History and address-bar suggestions. Bookmarks and open tabs stay.";
        a.showsSuppressionButton = YES; a.suppressionButton.title = @"Also remove cookies, site data and cache from this period"; a.suppressionButton.state = NSControlStateValueOff;
        [a addButtonWithTitle:@"Clear"]; [a addButtonWithTitle:@"Cancel"];
        NSWindow *win = m.webView.window ?: gWin.window;
        [a beginSheetModalForWindow:win completionHandler:^(NSModalResponse r) {
            if (r != NSAlertFirstButtonReturn) { reply(@NO, nil); return; }
            if (since <= 0) [VHistory.shared clear]; else [VHistory.shared removeSince:since];
            if (a.suppressionButton.state == NSControlStateValueOn)
                [ProfileStore(gWin && !gWin.isPrivate ? gWin.profile : @"") removeDataOfTypes:WKWebsiteDataStore.allWebsiteDataTypes modifiedSince:[NSDate dateWithTimeIntervalSince1970:since] completionHandler:^{}];
            [gWin showToast:@"History cleared"];
            reply(@YES, nil);
        }];
        return;
    }
    if ([op isEqualToString:@"open"]) {
        NSURL *u = WebURL(b[@"url"]); NSString *how = [b[@"how"] isKindOfClass:NSString.class] ? b[@"how"] : @"here";
        if (!u) { reply(@NO, nil); return; }
        if ([how isEqualToString:@"tab"]) [win newTab:u select:YES];
        else if ([how isEqualToString:@"bg"]) [win newTab:u select:NO];
        else [win openURL:u newTab:NO];
        reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"copy"]) {
        NSString *s = [b[@"text"] isKindOfClass:NSString.class] ? b[@"text"] : @"";
        [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
        reply(@YES, nil); return;
    }
    if ([op isEqualToString:@"reader.get"]) {
        NSString *ident = [b[@"id"] isKindOfClass:NSString.class] ? b[@"id"] : @"";
        reply(gReader[ident] ?: @{}, nil); return;
    }
    if ([op isEqualToString:@"reader.prefs"]) {
        if ([b[@"set"] isKindOfClass:NSDictionary.class]) [Defaults() setObject:b[@"set"] forKey:@"readerPrefs"];
        reply([Defaults() dictionaryForKey:@"readerPrefs"] ?: @{}, nil); return;
    }
    if ([op isEqualToString:@"toast"]) {
        if ([b[@"text"] isKindOfClass:NSString.class]) [gWin showToast:b[@"text"]];
        reply(@YES, nil); return;
    }

    if ([op isEqualToString:@"bm.tree"]) { reply(@{@"v": @(gBmVersion), @"tree": VBookmarks.shared.bar}, nil); return; }
    if ([op isEqualToString:@"bm.replace"]) {
        if ([b[@"v"] integerValue] != gBmVersion) { reply(@{@"stale": @YES, @"v": @(gBmVersion), @"tree": VBookmarks.shared.bar}, nil); return; }
        if (![b[@"tree"] isKindOfClass:NSArray.class]) { reply(nil, @"bad tree"); return; }
        NSMutableArray *bar = [NSMutableArray array];
        for (id n in b[@"tree"]) { NSMutableDictionary *k = CleanNode(n, 0); if (k) [bar addObject:k]; }
        VBookmarks.shared.bar = bar; [VBookmarks.shared save]; BookmarksChanged();
        reply(@{@"v": @(gBmVersion), @"tree": bar}, nil); return;
    }
    if ([op isEqualToString:@"bm.sources"]) { reply(ImportSources(), nil); return; }
    if ([op isEqualToString:@"bm.import"]) {
        NSString *err = nil;
        NSArray *t = ImportTree([b[@"source"] isKindOfClass:NSString.class] ? b[@"source"] : @"", &err);
        NSMutableArray *clean = [NSMutableArray array];
        for (id n in t ?: @[]) { NSMutableDictionary *k = CleanNode(n, 0); if (k) [clean addObject:k]; }
        reply(t ? @{@"tree": clean} : @{@"error": err ?: @"Nothing to import."}, nil); return;
    }
    if ([op isEqualToString:@"bm.export"]) {
        NSString *html = [b[@"html"] isKindOfClass:NSString.class] ? b[@"html"] : @"";
        NSSavePanel *p = [NSSavePanel savePanel];
        NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd";
        p.nameFieldStringValue = [NSString stringWithFormat:@"Flint Bookmarks %@.html", [f stringFromDate:NSDate.date]];
        p.directoryURL = gWin.downloadFolder;
        [p beginSheetModalForWindow:m.webView.window ?: gWin.window completionHandler:^(NSModalResponse r) {
            BOOL ok = r == NSModalResponseOK && [[html dataUsingEncoding:NSUTF8StringEncoding] writeToURL:p.URL atomically:YES];
            if (ok) [gWin showToast:[NSString stringWithFormat:@"Saved %@", p.URL.lastPathComponent]];
            reply(@(ok), nil);
        }];
        return;
    }
    if ([op isEqualToString:@"bm.openAll"]) {
        NSArray *urls = [b[@"urls"] isKindOfClass:NSArray.class] ? b[@"urls"] : @[];
        NSUInteger n = 0;
        for (id s in urls) { NSURL *u = WebURL(s); if (!u) continue; [win newTab:u select:n == 0]; if (++n >= 40) break; }
        reply(@(n), nil); return;
    }
    if ([op isEqualToString:@"bm.tabs"]) {
        NSMutableArray *out = [NSMutableArray array];
        for (VTab *t in win.tabs) if (WebURL(t.url) && ![t.url hasPrefix:@"flint:"]) [out addObject:@{@"name": t.title ?: @"", @"url": t.url}];
        reply(out, nil); return;
    }
    reply(nil, @"unknown op");
}

@end

static void FlintInternalInstall(WKWebViewConfiguration *c, WKUserContentController *ucc) {
    if (![c urlSchemeHandlerForURLScheme:@"flint"]) [c setURLSchemeHandler:VInternal.shared forURLScheme:@"flint"];
    static NSHashTable *done;
    if (!done) done = [NSHashTable weakObjectsHashTable];
    if (ucc && ![done containsObject:ucc]) { [done addObject:ucc]; [ucc addScriptMessageHandlerWithReply:VInternal.shared contentWorld:WKContentWorld.pageWorld name:@"flintInternal"]; }
}

@implementation VWindow (Internal)
- (void)openInternal:(NSString *)name {
    NSString *prefix = [NSString stringWithFormat:@"flint://%@", name];
    for (VTab *t in self.tabs) if ([t.url hasPrefix:prefix]) { [self selectTab:t]; return; }
    [self newTab:[NSURL URLWithString:prefix] select:YES];
}
- (void)showHistory:(id)s { [self openInternal:@"history"]; }
- (void)showBookmarks:(id)s { [self openInternal:@"bookmarks"]; }
- (void)showDownloadManager:(id)s { [self openInternal:@"downloads"]; }
// flint://settings#<section>: switch to the open settings tab (and its section), or open one
- (void)showSettingsSection:(NSString *)section {
    for (VTab *t in self.tabs) if ([t.url hasPrefix:@"flint://settings"]) {
        [self selectTab:t];
        [t.web.web evaluateJavaScript:[NSString stringWithFormat:@"location.hash='#%@'", section] completionHandler:nil];
        return;
    }
    [self newTab:[NSURL URLWithString:[@"flint://settings#" stringByAppendingString:section]] select:YES];
}
- (void)bookmarkAllTabs:(id)s {
    NSMutableArray *kids = [NSMutableArray array];
    for (VTab *t in self.tabs) if ([t.url hasPrefix:@"http"]) [kids addObject:[NSMutableDictionary dictionaryWithDictionary:@{@"name": t.title ?: @"", @"url": t.url}]];
    if (!kids.count) { [self showToast:@"No web pages open"]; return; }
    NSDateFormatter *f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle; f.timeStyle = NSDateFormatterShortStyle;
    NSString *name = [NSString stringWithFormat:@"Tabs · %@", [f stringFromDate:NSDate.date]];
    [VBookmarks.shared.bar addObject:[NSMutableDictionary dictionaryWithDictionary:@{@"name": name, @"children": kids}]];
    [VBookmarks.shared save]; BookmarksChanged();
    [self showToast:[NSString stringWithFormat:@"Bookmarked %lu tabs in “%@”", (unsigned long)kids.count, name]];
}
@end
#pragma mark - Browser window

@interface VRoot : NSView
@end
@implementation VRoot
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r { [vBg setFill]; NSRectFill(NSIntersectionRect(r, self.bounds)); }
- (void)resizeSubviewsWithOldSize:(NSSize)s { [WinFor(self) layout]; }
@end

// The page frame's struck corners, drawn as two tiny views over the page. (A mask on the page itself would
// make the Mac re-composite the whole page every frame, which costs real speed.)
// the page area never drags the window (only the sidebar's empty space and the title bar do)
@interface VContentView : NSView
@end
@implementation VContentView
- (BOOL)mouseDownCanMoveWindow { return NO; }
@end

@interface VCornerCap : NSView
@property BOOL bottomRight;
@end
@implementation VCornerCap
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)dirty {
    CGFloat c = NSWidth(self.bounds);
    NSBezierPath *tri = [NSBezierPath bezierPath], *edge = [NSBezierPath bezierPath];
    if (self.bottomRight) { [tri moveToPoint:NSMakePoint(c, c)]; [tri lineToPoint:NSMakePoint(0, c)]; [tri lineToPoint:NSMakePoint(c, 0)]; }
    else { [tri moveToPoint:NSMakePoint(0, 0)]; [tri lineToPoint:NSMakePoint(c, 0)]; [tri lineToPoint:NSMakePoint(0, c)]; }
    [tri closePath]; [vBg setFill]; [tri fill];
    [edge moveToPoint:NSMakePoint(c, 0)]; [edge lineToPoint:NSMakePoint(0, c)];
    edge.lineWidth = 1; [vBorder setStroke]; [edge stroke];
}
@end

@interface VWindow ()
@property (strong) VCornerCap *capTL, *capBR;
@property BOOL chromePending;
@property (strong) VSideHandle *sideHandle;
@property NSUInteger lastTyped;
@property (copy) NSString *completion;
@property (strong) NSTimer *saveTimer;
@property (strong) NSTextField *linkStatus;
@property BOOL pageFull, enteredForPage;
@property (strong) NSMutableDictionary<NSString *, NSArray *> *netSuggestions;
@property (weak) NSTextField *typingField;   // the address bar, or the box on a new tab
@end

static const CGFloat kTop = 40, kBook = 30; // kTop: toolbar height in full screen; windowed it's the title bar's

@implementation VWindow

// The first window restores the saved session; later ones start empty (or from their saved state).
- (instancetype)init { return [self initPrivate:NO state:[Defaults() dictionaryForKey:kTabsState] ?: @{}]; }

- (instancetype)initPrivate:(BOOL)priv state:(NSDictionary *)state {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1320, 860)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:w])) return nil;
    _isPrivate = priv;
    if (priv) _privateStore = WKWebsiteDataStore.nonPersistentDataStore;
    NSString *pid = [state[@"profile"] isKindOfClass:NSString.class] ? state[@"profile"] : @"";
    BOOL known = NO; for (NSDictionary *p in Profiles()) if ([p[@"id"] isEqualToString:pid]) known = YES;
    _profile = priv || !known ? @"" : [pid copy];   // a deleted profile's window comes back in the first profile
    VWindow *previous = gWin;
    BOOL firstNormal = !priv && ![gWindows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isPrivate == NO"]].count;
    if (!gWindows) gWindows = [NSMutableArray array];
    [gWindows addObject:self];
    gWin = self;
    w.titlebarAppearsTransparent = YES; w.titleVisibility = NSWindowTitleHidden;
    w.backgroundColor = vBg; w.minSize = NSMakeSize(640, 420);
    w.appearance = ThemeAppearance();
    w.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    w.delegate = self;
    w.title = priv ? @"Flint · Private" : _profile.length ? [@"Flint · " stringByAppendingString:ProfileName(_profile)] : @"Flint";
    // An empty unified-compact toolbar gives a native ~40pt title bar: macOS itself centres the
    // traffic lights and keeps the height right on every screen, so our bar is never clipped.
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"FlintToolbar"];
    tb.showsBaselineSeparator = NO; tb.allowsUserCustomization = NO;
    w.toolbar = tb;
    if (@available(macOS 11.0, *)) w.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    if (firstNormal) {
        w.frameAutosaveName = @"FlintMain";
        if (![w setFrameUsingName:@"FlintMain"]) [w center];
    } else if ([state[@"frame"] isKindOfClass:NSString.class] && NSWidth(NSRectFromString(state[@"frame"])) > 300) {
        [w setFrame:NSRectFromString(state[@"frame"]) display:NO];
    } else if (previous.window) {
        [w setFrame:previous.window.frame display:NO];
        NSPoint tl = NSMakePoint(NSMinX(previous.window.frame), NSMaxY(previous.window.frame));
        [w cascadeTopLeftFromPoint:NSMakePoint(tl.x + 26, tl.y - 26)];
    } else [w center];

    self.tabs = [NSMutableArray array];
    self.closed = [NSMutableArray array];

    VRoot *root = [[VRoot alloc] initWithFrame:w.contentView.bounds];
    w.contentView = root;
    self.toolbar = [[VToolbar alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(root.bounds), kTop)];
    self.bookmarksBar = [[VBookmarksBar alloc] initWithFrame:NSZeroRect];
    self.sidebar = [[VSidebar alloc] initWithFrame:NSMakeRect(0, 0, 230, 400)];
    self.sideScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.sideScroll.documentView = self.sidebar;
    self.sideScroll.drawsBackground = NO; self.sideScroll.hasVerticalScroller = YES; self.sideScroll.autohidesScrollers = YES;
    self.sideScroll.scrollerStyle = NSScrollerStyleOverlay; self.sideScroll.borderType = NSNoBorder;
    self.content = [[VContentView alloc] initWithFrame:NSZeroRect];
    self.content.wantsLayer = YES;
    self.content.layer.backgroundColor = vContentBg.CGColor;
    // the spark that runs along the top edge of the page while it loads
    CAGradientLayer *ember = [CAGradientLayer layer];
    ember.name = @"ember"; ember.startPoint = CGPointMake(0, 0.5); ember.endPoint = CGPointMake(1, 0.5); ember.zPosition = 900; ember.hidden = YES;
    [self.content.layer addSublayer:ember];
    self.home = [[VHome alloc] initWithFrame:NSZeroRect];
    self.home.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.findBar = [[VFindBar alloc] initWithFrame:NSMakeRect(0, 0, 330, 36)];
    self.findBar.hidden = YES;
    self.railDock = [[VRailDock alloc] initWithFrame:NSMakeRect(0, 0, 230, 42)];
    self.capTL = [[VCornerCap alloc] initWithFrame:NSZeroRect]; self.capBR = [[VCornerCap alloc] initWithFrame:NSZeroRect]; self.capBR.bottomRight = YES;
    for (NSView *v in @[self.bookmarksBar, self.sideScroll, self.railDock, self.content, self.capTL, self.capBR]) [root addSubview:v];
    self.suggest = [VSuggest new];
    for (NSView *v in @[root, self.toolbar, self.bookmarksBar, self.sidebar, self.sideScroll, self.home, self.findBar, self.content]) Clip(v);

    self.toast = [NSTextField labelWithString:@""];
    self.toast.font = UIFont(12.5, NSFontWeightMedium); self.toast.textColor = vText;
    self.toast.wantsLayer = YES; self.toast.layer.backgroundColor = vToast.CGColor;
    self.toast.alignment = NSTextAlignmentCenter; self.toast.alphaValue = 0;

    self.linkStatus = [NSTextField labelWithString:@""];
    self.linkStatus.font = UIFont(11.5, NSFontWeightRegular); self.linkStatus.textColor = vDim;
    self.linkStatus.wantsLayer = YES; self.linkStatus.layer.backgroundColor = vLinkBg.CGColor;
    self.linkStatus.lineBreakMode = NSLineBreakByTruncatingMiddle;

    [self restoreFrom:state];
    [self layout];
    [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(sleepIdleTabs) userInfo:nil repeats:YES];
    return self;
}

#pragma mark Pages

#pragma mark Profiles

// The window for a profile: the frontmost one already open, or a new one.
static VWindow *OpenProfileWindow(NSString *pid) {
    for (VWindow *w in gWindows.reverseObjectEnumerator) if (!w.isPrivate && [w.profile isEqualToString:pid ?: @""]) { [w.window makeKeyAndOrderFront:nil]; return w; }
    VWindow *w = [[VWindow alloc] initPrivate:NO state:@{@"profile": pid ?: @""}];
    [w showWindow:nil]; [w windowDidResize:nil];
    return w;
}
static NSString *CreateProfile(NSString *name) {
    NSString *pid = NSUUID.UUID.UUIDString;
    NSMutableArray *a = [[Defaults() arrayForKey:kProfiles] ?: @[] mutableCopy];
    NSMutableSet *used = [NSMutableSet set]; for (NSDictionary *p in Profiles()) [used addObject:@(ProfileColorIndex(p[@"id"]))];
    NSInteger color = 0; while (color < (NSInteger)ProfileColors().count - 1 && [used containsObject:@(color)]) color++;   // the first colour not taken
    [a addObject:@{@"id": pid, @"name": name.length ? name : [NSString stringWithFormat:@"Profile %lu", (unsigned long)a.count + 2], @"color": @(color)}];
    [Defaults() setObject:a forKey:kProfiles];
    for (VWindow *w in gWindows) [w.toolbar layoutBar];
    return pid;
}
- (void)profileMenu:(id)s {
    NSMenu *m = [self profilesMenu];
    NSView *at = [s isKindOfClass:NSView.class] ? s : self.toolbar;
    if (at == (NSView *)self.toolbar.profileBtn) PopMenuRight(m, NSMakePoint(NSWidth(at.bounds), NSHeight(at.bounds) + 6), at);
    else PopMenu(m, NSMakePoint(0, NSHeight(at.bounds) + 4), at);
}
// Every profile (this window's ticked), then New and Manage: the toolbar avatar and the ⋯ menu both show this.
- (NSMenu *)profilesMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Profiles"];
    for (NSDictionary *p in Profiles()) {
        NSMenuItem *i = [m addItemWithTitle:p[@"name"] action:@selector(openProfile:) keyEquivalent:@""];
        i.target = self; i.representedObject = p[@"id"]; i.state = [p[@"id"] isEqualToString:self.profile] && !self.isPrivate ? NSControlStateValueOn : NSControlStateValueOff;
        i.image = ProfileAvatar(p[@"id"], p[@"name"], 16);
    }
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"New Profile…" action:@selector(newProfile:) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Manage Profiles…" action:@selector(manageProfiles:) keyEquivalent:@""].target = self;
    return m;
}
- (void)openProfile:(NSMenuItem *)i { OpenProfileWindow(i.representedObject); }
- (void)manageProfiles:(id)s { [self showSettingsSection:@"profiles"]; }
- (void)newProfile:(id)s {
    NSAlert *a = [NSAlert new]; a.messageText = @"New profile";
    a.informativeText = @"A profile keeps its own sign-ins, cookies, history and tabs. Bookmarks and extensions are shared.";
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)]; f.placeholderString = @"Name, e.g. Work";
    a.accessoryView = f; [a addButtonWithTitle:@"Create"]; [a addButtonWithTitle:@"Cancel"];
    a.window.initialFirstResponder = f;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        OpenProfileWindow(CreateProfile(Trim(f.stringValue)));
    }];
}

- (WKWebViewConfiguration *)pageConfig { return self.isPrivate ? PrivateConfig(self.privateStore) : ProfileConfig(self.profile); }

- (VPage *)makePage:(VTab *)t {
    t.owner = self;
    VPage *p = (self.isPrivate || self.profile.length) ? [[VPage alloc] initWithFrame:self.content.bounds web:[[FWebView alloc] initWithFrame:self.content.bounds configuration:[self pageConfig]]]
                                                       : [[VPage alloc] initWithFrame:self.content.bounds];
    p.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    p.tab = t;
    t.web = p; t.isHome = NO;
    ApplyThrottle(p.web, ThrottleHard());
    if (t.savedBack.count) [p.back setArray:t.savedBack];
    t.savedBack = nil;
    return p;
}

- (void)pageChanged:(VPage *)p {
    VTab *t = p.tab; if (!t) return;
    if (p.title.length) t.title = p.title;
    NSString *oldHost = t.url ? HostOf([NSURL URLWithString:t.url]) : nil;
    if (p.url) t.url = p.url;
    t.loading = p.loading; t.progress = p.progress; t.blocked = p.blocked;
    NSURL *u = t.url ? [NSURL URLWithString:t.url] : nil;
    NSString *host = HostOf(u);
    if (u && (!t.favicon || ![oldHost isEqualToString:host])) {
        t.favicon = [VFavicons.shared iconForURL:t.url];
        if (!t.favicon && [u.scheme hasPrefix:@"http"]) {
            __weak VTab *wt = t;
            [VFavicons.shared fetchFor:u href:nil done:^(NSImage *im) { if ([HostOf([NSURL URLWithString:wt.url]) isEqualToString:host]) { wt.favicon = im; [self refreshChrome]; [self.bookmarksBar reload]; } }];
        }
    }
    if (!p.loading) {
        NSNumber *z = [Defaults() dictionaryForKey:kZoom][host] ?: [Defaults() objectForKey:kDefaultZoom];
        if (z && fabs(z.doubleValue - p.zoom) > 0.01) [p setZoomLevel:z.doubleValue];
    }
    // pages report progress many times a second; the toolbar and sidebar redraw at most ~20 times a second
    if (!self.chromePending) { self.chromePending = YES; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ self.chromePending = NO; [self refreshChrome]; }); }
    [self scheduleSave];
}

- (void)showLink:(NSString *)u {
    if (!u.length) { [self.linkStatus removeFromSuperview]; return; }
    self.linkStatus.stringValue = [NSString stringWithFormat:@"  %@  ", u];
    [self.linkStatus sizeToFit];
    // bottom-right corner of the page, full address unless it's wider than most of the page
    NSRect cb = self.content.bounds;
    CGFloat w = MIN(NSWidth(self.linkStatus.frame) + 4, NSWidth(cb) - 16);
    CGFloat y = self.content.isFlipped ? NSHeight(cb) - 28 : 8;
    self.linkStatus.frame = NSMakeRect(NSWidth(cb) - w - 8, y, w, 20);
    FacetView(self.linkStatus, 6, vSep);
    if (self.linkStatus.superview != self.content) [self.content addSubview:self.linkStatus];
}

#pragma mark Tabs

- (void)newTab:(NSURL *)u select:(BOOL)sel {
    VTab *t = [VTab new]; t.owner = self;
    t.isHome = (u == nil);
    NSUInteger at = self.current ? [self.tabs indexOfObject:self.current] + 1 : self.tabs.count;
    NSUInteger firstLoose = [self.tabs indexesOfObjectsPassingTest:^BOOL(VTab *x, NSUInteger i, BOOL *s) { return x.pinned; }].count;
    if (at < firstLoose) at = self.tabs.count;
    [self.tabs insertObject:t atIndex:MIN(at, self.tabs.count)];
    if (u) {
        t.url = u.absoluteString; t.title = HostOf(u);
        t.favicon = [VFavicons.shared iconForURL:t.url];
        VPage *p = [self makePage:t];
        [p open:t.url record:NO];
        if (!sel) t.hiddenAt = NSDate.date.timeIntervalSince1970;
    }
    if (sel || !self.current) [self selectTab:t];
    else [self refreshChrome];
    if (sel && !u) [self focusAddress];
    [self.sidebar reload];
    [self scheduleSave];
}

- (void)selectTab:(VTab *)t {
    if (!t) return;
    VTab *was = self.current;
    if (was) t.deferred = NO;   // you chose it: it loads
    if (was != t) [self autoPiPLeaving:was entering:t];   // asked while the old page is still on screen
    if (self.current && self.current != t) self.current.hiddenAt = NSDate.date.timeIntervalSince1970;
    self.current = t;
    [FExtHost.shared tab:t event:@"activated"];
    if (self.mediaTab) dispatch_async(dispatch_get_main_queue(), ^{ [self updateNowPlaying]; });
    [self showLink:nil];
    if (t.isHome) {
        [self placePages];
        [self.home reload];
        // a new tab is for typing: the address bar takes focus once the click or key that opened it is done
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.current == t && t.isHome && (self.window.isKeyWindow || !NSApp.keyWindow)) { self.home.field.stringValue = @""; [self.window makeFirstResponder:self.home.field ?: self.toolbar.field]; }
        });
    } else {
        [self placePages];   // wakes the tab if it was asleep; in split view its partner shows too
        [t.web focus];
    }
    if (!self.findBar.hidden) [self.content addSubview:self.findBar];
    [self.suggest dismiss];
    [self refreshChrome];
    [self.sidebar reload];
    [self scheduleSave];
}

// Background tabs give their memory back after a while; they reload when you return.
- (void)sleepIdleTabs {
    NSInteger mins = [Defaults() integerForKey:kSleepMins];
    if (mins <= 0) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (VTab *t in self.tabs.copy) {
        if (t == self.current || !t.web || t.hiddenAt <= 0 || now - t.hiddenAt < mins * 60) continue;
        if ([self.splitPair containsObject:t] && [self.splitPair containsObject:self.current]) continue;
        if (t.audible) continue;   // never silence something you're listening to
        [self sleep:t];
    }
}
- (void)sleep:(VTab *)t {
    t.savedBack = [t.web historyForSleep];
    t.savedState = [t.web sessionState];
    if (t.mediaTime > 0) t.resumeAt = t.mediaTime;   // it wakes where its video was
    [t.web close];
    t.web = nil;
    [self.sidebar reload];
}

- (void)closeTab:(VTab *)t {
    NSUInteger i = [self.tabs indexOfObject:t]; if (i == NSNotFound) return;
    if (t.url && !t.isHome) {   // remembered with its back/forward history, so reopening brings all of it back
        NSMutableDictionary *d = [@{@"url": t.url, @"title": t.title ?: @""} mutableCopy];
        id st = t.web ? [t.web sessionState] : t.savedState;
        if ([st isKindOfClass:NSData.class] && [st length] < 400000) d[@"state"] = st;
        double at = t.resumeAt > 0 ? t.resumeAt : t.mediaTime;
        if (at > 0 && t.mediaKey.length) { d[@"mediaTime"] = @(at); d[@"mediaKey"] = t.mediaKey; }
        [self.closed addObject:d];
        if (self.closed.count > 25) [self.closed removeObjectAtIndex:0];
    }
    [FExtHost.shared tab:t event:@"removed"];
    VTab *partner = nil;   // closing half of a split leaves the other half in front
    if ([self.splitPair containsObject:t]) { partner = self.splitPair[0] == t ? self.splitPair[1] : self.splitPair[0]; [self endSplit]; }
    [t.web close]; t.web = nil;
    [self.tabs removeObjectAtIndex:i];
    if (t == self.mediaTab) { self.mediaTab = nil; dispatch_async(dispatch_get_main_queue(), ^{ [self updateNowPlaying]; }); }
    if (t == self.current) {
        self.current = nil;
        if (!self.tabs.count) {
            if (gWindows.count > 1) { [self.sidebar reload]; dispatch_async(dispatch_get_main_queue(), ^{ [self.window performClose:nil]; }); return; }
            [self newTab:nil select:YES]; return;
        }
        [self selectTab:partner && [self.tabs containsObject:partner] ? partner : self.tabs[MIN(i, self.tabs.count - 1)]];
    } else if (partner) [self placePages];
    [self.sidebar reload];
    [self scheduleSave];
}

- (void)moveTab:(VTab *)t to:(NSInteger)i {
    [self.tabs removeObject:t];
    [self.tabs insertObject:t atIndex:(NSUInteger)MAX(0, MIN((NSInteger)self.tabs.count, i))];
    [self.sidebar reload]; [self scheduleSave];
}

- (void)togglePin:(VTab *)t {
    t.pinned = !t.pinned;
    NSArray *p = [self.tabs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pinned == YES"]];
    NSArray *l = [self.tabs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pinned == NO"]];
    [self.tabs setArray:[p arrayByAddingObjectsFromArray:l]];
    [self.sidebar reload]; [self scheduleSave];
}

- (void)tabMenu:(VTab *)t at:(NSPoint)p inView:(NSView *)v {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *(^add)(NSString *, SEL) = ^NSMenuItem *(NSString *title, SEL a) {
        NSMenuItem *it = [m addItemWithTitle:title action:a keyEquivalent:@""]; it.target = self; it.representedObject = t; return it;
    };
    if (t.web) add(@"Reload Tab", @selector(menuReload:));
    add(t.pinned ? @"Unpin Tab" : @"Pin Tab", @selector(menuPin:));
    add(@"Duplicate Tab", @selector(menuDuplicate:));
    if (t.url && !t.isHome) {
        add(@"Copy Link", @selector(menuCopyLink:));
        add([VBookmarks.shared find:t.url] ? @"Remove Bookmark" : @"Bookmark Tab", @selector(menuBookmark:));
    }
    if (t.web && (t.audible || t.muted)) add(t.muted ? @"Unmute Tab" : @"Mute Tab", @selector(menuMute:));
    if (t.web && t != self.current) add(@"Put Tab to Sleep", @selector(menuSleep:));
    [m addItem:NSMenuItem.separatorItem];
    add([self.splitPair containsObject:t] ? @"Exit Split View" : t == self.current ? @"New Split View" : @"Split View with Current Tab", @selector(menuSplit:));
    if ([self.splitPair containsObject:t]) add(@"Swap Sides", @selector(swapSplit:));
    add(@"Move Tab to New Window", @selector(menuMoveToWindow:)).enabled = self.tabs.count > 1;
    [m addItem:NSMenuItem.separatorItem];
    add(@"Close Tab", @selector(menuClose:));
    add(@"Close Other Tabs", @selector(menuCloseOthers:));
    add(@"Close Tabs Below", @selector(menuCloseBelow:));
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *ro = add(@"Reopen Closed Tab", @selector(reopenClosed:)); ro.enabled = self.closed.count > 0;
    PopMenu(m, p, v);
}
- (void)menuPin:(NSMenuItem *)i { [self togglePin:i.representedObject]; }
- (void)menuReload:(NSMenuItem *)i { VTab *t = i.representedObject; [t.web reload]; }
- (void)menuBookmark:(NSMenuItem *)i { VTab *t = i.representedObject; [VBookmarks.shared toggle:t.url title:t.title]; [self.bookmarksBar reload]; [self refreshChrome]; }
- (void)saveImageAs:(NSMenuItem *)m { gAskNextDownload = YES; [self.current.web download:m.representedObject]; }
- (void)openBookmarkInBackground:(NSMenuItem *)m { [self newTab:[NSURL URLWithString:m.representedObject] select:NO]; }
- (void)menuMute:(NSMenuItem *)i { VTab *t = i.representedObject; [t.web setMuted:!t.muted]; }
- (void)muteCurrent:(id)s { VTab *t = self.current; if (t.web) { [t.web setMuted:!t.muted]; [self showToast:t.muted ? @"Tab muted" : @"Tab unmuted"]; } }
- (void)pictureInPicture:(id)s { [self.current.web pictureInPicture]; }
- (void)menuDuplicate:(NSMenuItem *)i { VTab *t = i.representedObject; if (t.url && !t.isHome) [self newTab:[NSURL URLWithString:t.url] select:YES]; else [self newTab:nil select:YES]; }
- (void)menuCopyLink:(NSMenuItem *)i { VTab *t = i.representedObject; [self copyString:t.url]; }
- (void)menuSleep:(NSMenuItem *)i { [self sleep:i.representedObject]; }
- (void)menuClose:(NSMenuItem *)i { [self closeTab:i.representedObject]; }
- (void)menuCloseOthers:(NSMenuItem *)i { for (VTab *t in self.tabs.copy) if (t != i.representedObject && !t.pinned) [self closeTab:t]; [self selectTab:i.representedObject]; }
- (void)menuCloseBelow:(NSMenuItem *)i {
    NSUInteger at = [self.tabs indexOfObject:i.representedObject];
    for (VTab *t in [self.tabs subarrayWithRange:NSMakeRange(at + 1, self.tabs.count - at - 1)]) if (!t.pinned) [self closeTab:t];
}

#pragma mark Session

- (void)scheduleSave {
    [self.saveTimer invalidate];
    self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(saveSession) userInfo:nil repeats:NO];
}
- (NSDictionary *)sessionDict {
    NSMutableArray *a = [NSMutableArray array];
    for (VTab *t in self.tabs) {
        NSString *u = t.web.url ?: t.url;
        NSMutableDictionary *d = [@{@"url": t.isHome || !u ? @"" : u, @"title": t.title ?: @"", @"pinned": @(t.pinned)} mutableCopy];
        id state = t.web ? [t.web sessionState] : t.savedState;   // back/forward history and scroll position
        if ([state isKindOfClass:NSData.class] && [state length] < 400000) d[@"state"] = state;
        double at = t.resumeAt > 0 ? t.resumeAt : t.mediaTime;   // where its video was
        if (at > 0 && t.mediaKey.length) { d[@"mediaTime"] = @(at); d[@"mediaKey"] = t.mediaKey; }
        [a addObject:d];
    }
    return @{@"tabs": a, @"current": @(self.current ? (NSInteger)[self.tabs indexOfObject:self.current] : 0), @"frame": NSStringFromRect(self.window.frame), @"profile": self.profile ?: @""};
}
// Every normal window is saved (the first as the main one); private windows never are.
- (void)saveSession {
    if (gQuitting) return;   // the quit already saved; nothing after it may replace that
    NSMutableArray *normal = [NSMutableArray array];
    for (VWindow *w in gWindows) if (!w.isPrivate) [normal addObject:[w sessionDict]];
    if (!normal.count) { [Defaults() setObject:@{@"tabs": @[], @"current": @0} forKey:kTabsState]; DLog(@"session: no windows left, nothing saved"); return; }
    NSMutableDictionary *main = [normal[0] mutableCopy];
    if (normal.count > 1) main[@"windows"] = [normal subarrayWithRange:NSMakeRange(1, normal.count - 1)];
    [Defaults() setObject:main forKey:kTabsState];
    static NSUInteger lastCount = NSNotFound; NSUInteger n = [main[@"tabs"] count];
    if (n != lastCount) { lastCount = n; DLog(@"session: %lu tabs saved", (unsigned long)n); }
}
- (void)restoreFrom:(NSDictionary *)s {
    BOOL restore = [Defaults() integerForKey:kStartup] == 0 && !self.isPrivate;
    if (!s[@"empty"]) for (NSDictionary *d in s[@"tabs"]) {
        BOOL pinned = [d[@"pinned"] boolValue];
        if (!restore && !pinned) continue;
        VTab *t = [VTab new]; t.owner = self;
        t.url = [d[@"url"] length] ? d[@"url"] : nil;
        t.isHome = t.url == nil; t.title = d[@"title"]; t.pinned = pinned;
        t.savedState = [d[@"state"] isKindOfClass:NSData.class] ? d[@"state"] : nil;
        if (t.url) t.favicon = [VFavicons.shared iconForURL:t.url];
        if ([d[@"mediaKey"] isKindOfClass:NSString.class] && [Defaults() boolForKey:kResumeMedia]) { t.mediaKey = d[@"mediaKey"]; t.mediaTime = t.savedMedia = t.resumeAt = [d[@"mediaTime"] doubleValue]; DLog(@"restoring a video at %.0f s", t.resumeAt); }
        [self.tabs addObject:t];
    }
    if (s[@"empty"]) return;   // a tab is about to be moved in
    if (!self.isPrivate) DLog(@"launch: %lu tabs restored (%lu saved)", (unsigned long)self.tabs.count, (unsigned long)[s[@"tabs"] count]);
    NSInteger cur = [s[@"current"] integerValue];
    if (!self.tabs.count) { [self newTab:nil select:YES]; return; }
    VTab *front = self.tabs[(NSUInteger)MAX(0, MIN((NSInteger)self.tabs.count - 1, cur))];
    if (!front.isHome) { front.launchRestored = [Defaults() boolForKey:kRestorePaused]; front.deferred = [Defaults() boolForKey:kLazyRestore]; front.launchFront = YES; }
    [self selectTab:front];
}

#pragma mark Windows

- (void)windowDidBecomeKey:(NSNotification *)n {
    gWin = self;
    static id mon;   // clicks and keys in a page mark that tab as "yours right now" for the CPU rule
    if (!mon) mon = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        VWindow *w = WinFor(e.window); VTab *t = w.current;
        if (t && e.window == w.window) t.lastInput = NSDate.date.timeIntervalSince1970;
        return e;
    }];
}
- (void)moveTabToNewWindow:(VTab *)t {
    if (!t || ![self.tabs containsObject:t]) return;
    if (self.tabs.count == 1) { [self showToast:@"This is the only tab in the window"]; return; }
    if ([self.splitPair containsObject:t]) { [self endSplit]; [self placePages]; }
    VWindow *nw = [[VWindow alloc] initPrivate:self.isPrivate state:@{@"empty": @YES, @"profile": self.profile ?: @""}];
    NSUInteger i = [self.tabs indexOfObject:t];
    [self.tabs removeObjectAtIndex:i];
    if (t == self.current) { self.current = nil; [self selectTab:self.tabs[MIN(i, self.tabs.count - 1)]]; }
    [t.web removeFromSuperview];
    t.owner = nil; [nw.tabs addObject:t]; t.owner = nw;
    [nw selectTab:t];
    [nw showWindow:nil]; [nw layout];
    [self.sidebar reload]; [nw.sidebar reload];
    [self scheduleSave];
}
- (void)menuMoveToWindow:(NSMenuItem *)i { [self moveTabToNewWindow:i.representedObject]; }
- (void)moveCurrentToNewWindow:(id)s { [self moveTabToNewWindow:self.current]; }
// Home: this tab goes back to the new tab page (its web page closes, like opening a new tab in place).
- (void)goHome:(id)s {
    VTab *t = self.current; if (!t || t.isHome) { [self focusAddress]; return; }
    if (t.url) [self.closed addObject:@{@"url": t.url, @"title": t.title ?: @""}];
    [t.web removeFromSuperview]; [t.web close]; t.web = nil;
    t.isHome = YES; t.url = nil; t.title = nil; t.favicon = nil; t.savedState = nil; t.loading = NO;
    [self selectTab:t];
    [self scheduleSave];
}

#pragma mark Layout and chrome

- (void)layout {
    NSView *root = self.window.contentView;
    CGFloat W = NSWidth(root.bounds), H = NSHeight(root.bounds);
    self.toolbar.hidden = self.pageFull;
    if (self.pageFull) {   // a video went full screen: the page gets everything
        self.bookmarksBar.hidden = YES; self.sideScroll.hidden = YES; self.railDock.hidden = YES; self.nowPlaying.hidden = YES; self.sideHandle.hidden = YES;
        self.content.frame = root.bounds; [self placePages];
        self.content.layer.borderWidth = 0; self.content.layer.cornerRadius = 0; self.capTL.hidden = self.capBR.hidden = YES;
        return;
    }
    BOOL fs = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    BOOL showBook = [Defaults() boolForKey:kShowBookmarks];
    BOOL sideHidden = [Defaults() boolForKey:kSidebarHidden];
    CGFloat side = sideHidden ? 0 : SidebarWidth();
    BOOL compact = side > 0 && side < 100;
    self.toolbar.leftInset = fs ? 10 : 80;
    [self positionLights];
    // The toolbar lives inside the (enlarged) title bar so it draws above it and gets its clicks;
    // in full screen the title bar moves to its own window, so the toolbar returns to the content.
    NSView *titlebar = [self.window standardWindowButton:NSWindowCloseButton].superview;
    NSView *host = (!fs && titlebar) ? titlebar : root;
    if (self.toolbar.superview != host) { [self.toolbar removeFromSuperview]; [host addSubview:self.toolbar positioned:NSWindowBelow relativeTo:nil]; }
    CGFloat top = host == root ? kTop : MAX(28, NSHeight(titlebar.bounds));
    self.toolbar.frame = host == root ? NSMakeRect(0, 0, W, kTop) : titlebar.bounds;
    self.toolbar.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.toolbar layoutBar];
    CGFloat y = top;
    BOOL onRight = [Defaults() boolForKey:kSidebarRight];
    // Like Helium: the sidebar runs up to the toolbar and the bookmarks bar sits beside it, over the page,
    // so the first tab lines up with the bookmarks.
    self.bookmarksBar.hidden = !showBook;
    CGFloat pageTop = y + (showBook ? kBook : 0);
    if (showBook) self.bookmarksBar.frame = NSMakeRect(sideHidden || onRight ? 0 : side, y, W - side, kBook);
    self.sideScroll.hidden = sideHidden;
    CGFloat dockH = compact ? 5 * 32 + 14 : 42, npH = (self.nowPlaying && !self.nowPlaying.hidden && !sideHidden) ? (compact ? 56 : 64) : 0;
    self.sideScroll.frame = NSMakeRect(onRight ? W - side : 0, y, side, H - y - dockH - npH);
    if (self.nowPlaying) { self.nowPlaying.frame = NSMakeRect(onRight ? W - side : 0, H - dockH - npH, side, compact ? 56 : 64); if (sideHidden) self.nowPlaying.hidden = YES; }
    if (!self.sideHandle) self.sideHandle = [[VSideHandle alloc] initWithFrame:NSZeroRect];
    if (self.sideHandle.superview != root) [root addSubview:self.sideHandle positioned:NSWindowAbove relativeTo:nil];   // layout can run before the real content view is installed
    self.sideHandle.hidden = sideHidden; self.sideHandle.onRight = onRight;
    self.sideHandle.frame = NSMakeRect(onRight ? W - side - 6 : side - 6, y, 12, H - y);
    [self.window invalidateCursorRectsForView:self.sideHandle];
    self.railDock.hidden = sideHidden;
    self.railDock.frame = NSMakeRect(onRight ? W - side : 0, H - dockH, side, dockH);
    [self.sidebar reload];
    CGFloat cx = sideHidden || onRight ? 6 : side;
    CGFloat cw = W - cx - (sideHidden || !onRight ? 6 : side);
    self.content.frame = NSMakeRect(cx, pageTop + (showBook ? 0 : 2), cw, H - pageTop - 6 - (showBook ? 0 : 2));
    self.findBar.frame = NSMakeRect(NSWidth(self.content.bounds) - 344, 10, 330, 36);
    FacetView(self.findBar, 10, vLine);
    [self frameContent];
    [self placePages];
    [self updateEmber];
    self.bookmarksBar.needsDisplay = YES;
}

// Theme switch: new colours everywhere, without a relaunch.
static void RedrawTree(NSView *v) { v.needsDisplay = YES; for (NSView *s in v.subviews) RedrawTree(s); }
- (void)frameContent {
    CALayer *L = self.content.layer;
    L.mask = nil; L.cornerRadius = 10; L.masksToBounds = YES;
    if (@available(macOS 11.0, *)) L.cornerCurve = kCACornerCurveContinuous;
    L.borderWidth = 1; L.borderColor = vBorder.CGColor;
    self.capTL.hidden = self.capBR.hidden = YES;
}

// While the page loads, a spark sweeps the top edge of the page frame, growing with progress.
- (void)updateEmber {
    CAGradientLayer *e = nil;
    for (CALayer *l in self.content.layer.sublayers) if ([l.name isEqualToString:@"ember"]) e = (CAGradientLayer *)l;
    if (!e) return;
    VPage *w = self.current.web;
    BOOL on = w.loading && !self.pageFull;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGFloat W = NSWidth(self.content.bounds), H = NSHeight(self.content.bounds);
    e.frame = CGRectMake(14, H - 2, W - 28, 2);
    NSColor *ink = [Defaults() integerForKey:kAccent] == 0 ? vText : vAccent;   // loading: a quiet line, in the accent if you chose one
    e.colors = @[(id)[ink colorWithAlphaComponent:0].CGColor, (id)[ink colorWithAlphaComponent:0.35].CGColor, (id)[ink colorWithAlphaComponent:0.7].CGColor, (id)[ink colorWithAlphaComponent:0.35].CGColor, (id)[ink colorWithAlphaComponent:0].CGColor];
    e.locations = @[@0, @0.35, @0.5, @0.65, @1];
    e.shadowOpacity = 0;
    CGPathRef sp = CGPathCreateWithRect(CGRectMake(0, 0, W - 28, 2), NULL); e.shadowPath = sp; CGPathRelease(sp);   // explicit shape: no per-frame shadow pass
    e.hidden = !on;
    [CATransaction commit];
    if (on && ![e animationForKey:@"sweep"]) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"locations"];
        a.fromValue = @[@-0.6, @-0.25, @-0.1, @0.05, @0.4]; a.toValue = @[@0.6, @0.95, @1.1, @1.25, @1.6];
        a.duration = 1.1; a.repeatCount = HUGE_VALF; a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [e addAnimation:a forKey:@"sweep"];
    } else if (!on) [e removeAllAnimations];
}

- (void)applyTheme {
    self.window.appearance = ThemeAppearance();
    self.window.backgroundColor = vBg;
    self.content.layer.backgroundColor = vContentBg.CGColor;
    self.content.layer.borderColor = vBorder.CGColor;
    self.toast.layer.backgroundColor = vToast.CGColor; self.toast.textColor = ThemeIsLight() ? Hex(0xffffff) : vText;
    self.linkStatus.layer.backgroundColor = vLinkBg.CGColor; self.linkStatus.textColor = vDim;
    self.toolbar.field.textColor = vText;
    [self frameContent]; FacetView(self.findBar, 10, vLine);
    for (VTab *t in self.tabs) if (t.web) {
        t.web.layer.backgroundColor = vContentBg.CGColor;
        if (@available(macOS 12.0, *)) t.web.web.underPageBackgroundColor = vContentBg;
    }
    RedrawTree(self.window.contentView.superview ?: self.window.contentView);
    [self.bookmarksBar reload]; [self.sidebar reload]; [self layout]; [self refreshChrome];
}

// The title bar's height and the traffic lights are AppKit's (via the compact toolbar style).
- (void)positionLights {}
- (void)windowDidResize:(NSNotification *)n {
    NSView *root = self.window.contentView;
    NSRect want = root.superview.bounds;
    if (!NSEqualRects(root.frame, want) && NSWidth(want) > 0) root.frame = want;
    [self layout];
}
- (void)windowDidEnterFullScreen:(NSNotification *)n { [self layout]; }
- (void)windowDidChangeScreen:(NSNotification *)n { [self layout]; }
- (void)windowDidChangeBackingProperties:(NSNotification *)n { [self layout]; }
- (void)windowDidExitFullScreen:(NSNotification *)n {
    [self layout];
}
- (void)windowWillClose:(NSNotification *)n {
    [self.saveTimer invalidate];
    if (gQuitting) return;   // quitting: the saved tabs stay as they were
    [self.suggest dismiss];
    for (VTab *t in self.tabs) { [FExtHost.shared tab:t event:@"removed"]; [t.web close]; t.web = nil; }
    [self.tabs removeAllObjects];
    [gWindows removeObject:self];
    if (gWin == self) gWin = gWindows.lastObject;
    [self saveSession];
    [gWin.window makeKeyAndOrderFront:nil];
}
// Closing the last window quits, so every page gets to close cleanly first; other windows just close.
- (BOOL)windowShouldClose:(NSWindow *)w {
    if (gWindows.count > 1) return YES;
    [NSApp terminate:nil]; return NO;
}

// The address at rest reads like an instrument: the site in full strength, the rest of the path quietly after it.
- (NSAttributedString *)identityFor:(VTab *)t url:(NSURL *)u extension:(NSString *)extName {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *strong = @{NSFontAttributeName: UIFont(13, NSFontWeightMedium), NSForegroundColorAttributeName: vText, NSParagraphStyleAttributeName: ps};
    NSDictionary *quiet = @{NSFontAttributeName: UIFont(13, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint, NSParagraphStyleAttributeName: ps};
    NSMutableAttributedString *a = [NSMutableAttributedString new];
    if (t.isHome || !u) return a;
    if (extName) { [a appendAttributedString:[[NSAttributedString alloc] initWithString:extName attributes:strong]]; return a; }
    if ([u.scheme isEqualToString:@"flint"]) {
        NSString *orig = nil; for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO].queryItems) if ([q.name isEqualToString:@"u"]) orig = q.value;
        NSString *name = u.host.capitalizedString ?: @"Flint";
        [a appendAttributedString:[[NSAttributedString alloc] initWithString:name attributes:strong]];
        NSString *rest = orig ? HostOf([NSURL URLWithString:orig]) : @"Flint";
        if (rest.length) [a appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  ·  " stringByAppendingString:rest] attributes:quiet]];
        return a;
    }
    NSString *host = HostOf(u);
    if (!host.length) { [a appendAttributedString:[[NSAttributedString alloc] initWithString:u.absoluteString attributes:strong]]; return a; }
    [a appendAttributedString:[[NSAttributedString alloc] initWithString:host attributes:strong]];
    NSString *path = u.path ?: @"";
    if (path.length > 1) {
        if (path.length > 48) path = [[path substringToIndex:47] stringByAppendingString:@"…"];
        [a appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:path] attributes:quiet]];
    }
    return a;
}

- (void)refreshChrome {
    VTab *t = self.current;
    VToolbar *tb = self.toolbar;
    VPage *w = t.web;
    if (!tb.field.currentEditor) {
        tb.editing = NO;
        tb.field.alignment = NSTextAlignmentCenter;
        NSURL *u = t.url ? [NSURL URLWithString:t.url] : nil;
        NSString *extName = [u.scheme isEqualToString:@"chrome-extension"] ? [FExtHost.shared nameForID:u.host] : nil;
        tb.field.attributedStringValue = [self identityFor:t url:u extension:extName];
    }
    tb.backBtn.enabled = w.canGoBack; tb.fwdBtn.enabled = w.canGoForward;
    tb.reloadBtn.symbolName = w.loading ? @"xmark" : @"arrow.clockwise";
    tb.reloadBtn.toolTip = w.loading ? @"Stop" : @"Reload (⌘R)";
    NSString *scheme = [NSURL URLWithString:t.url ?: @""].scheme;
    tb.infoBtn.symbolName = t.isHome ? @"magnifyingglass" : [scheme isEqualToString:@"chrome-extension"] ? @"puzzlepiece.extension" : [scheme isEqualToString:@"flint"] ? @"sparkle" : [scheme isEqualToString:@"https"] ? @"lock.fill" : @"exclamationmark.triangle";
    tb.starBtn.hidden = t.isHome || !ToolbarShows(@"star");
    tb.pipBtn.hidden = !(t.web && (t.hasVideo || t.inPiP));
    tb.pipBtn.symbolName = t.inPiP ? @"pip.exit" : @"pip.enter";
    tb.pipBtn.toolTip = t.inPiP ? @"Return video to the page (⌃⌘P)" : @"Picture in Picture (⌃⌘P)";
    tb.pipBtn.active = t.inPiP; tb.pipBtn.needsDisplay = YES;
    [tb placePillButtons];    tb.readerBtn.enabled = [t.url hasPrefix:@"http"] || [t.url hasPrefix:@"flint://reader"];
    tb.readerBtn.active = [t.url hasPrefix:@"flint://reader"];
    tb.shareBtn.enabled = [t.url hasPrefix:@"http"];
    for (VButton *b in @[tb.readerBtn, tb.shareBtn, tb.homeBtn]) b.needsDisplay = YES;
    tb.starBtn.symbolName = [VBookmarks.shared find:t.url] ? @"star.fill" : @"star";
    tb.starBtn.active = [VBookmarks.shared find:t.url] != nil;
    tb.progress = w.loading ? MAX(0.08, t.progress) : 0;
    [self updateEmber];
    tb.blocked = t.blocked;
    tb.shieldBtn.active = NO;
    tb.shieldBtn.symbolName = [Defaults() boolForKey:kBlock] ? @"checkmark.shield" : @"shield.slash";
    for (VButton *b in @[tb.backBtn, tb.fwdBtn, tb.reloadBtn, tb.infoBtn, tb.starBtn, tb.shieldBtn]) b.needsDisplay = YES;
    tb.needsDisplay = YES;
    self.sidebar.needsDisplay = YES;
    self.window.title = t.title.length ? t.title : @"Flint";
}

#pragma mark Address bar

- (void)focusAddress {
    if (!self.window.isKeyWindow) [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.toolbar.field];
}

- (void)go:(NSString *)input {
    NSURL *u = URLFromInput(input);
    if (!u) return;
    [self.suggest dismiss];
    [self openURL:u newTab:NO];
}

- (void)openURL:(NSURL *)u newTab:(BOOL)nt {
    if (!u) return;
    if (nt || !self.current) { [self newTab:u select:!nt || !self.current]; return; }
    VTab *t = self.current;
    if ([Defaults() boolForKey:kStrip]) { NSURL *clean = StripTracking(u); if (clean) u = clean; }
    if (!t.web) {
        VPage *p = [self makePage:t];
        [self placePages];
        [p open:u.absoluteString record:NO];
    } else {
        [t.web open:u.absoluteString record:YES];
    }
    t.url = u.absoluteString;
    [t.web focus];
    [self refreshChrome];
}

// Commands you can strike from the address bar (type a few letters, or ">" to list them all).
static NSArray<NSDictionary *> *StrikeCommands(void) {
    return @[@{@"title": @"New Tab", @"sel": @"newTabAction:", @"keys": @"⌘T", @"symbol": @"plus.square"},
             @{@"title": @"New Window", @"sel": @"newWindow:", @"keys": @"⌘N", @"symbol": @"macwindow.badge.plus"},
             @{@"title": @"New Private Window", @"sel": @"newPrivateWindow:", @"keys": @"⇧⌘N", @"symbol": @"eye.slash"},
             @{@"title": @"Reopen Closed Tab", @"sel": @"reopenClosed:", @"keys": @"⇧⌘T", @"symbol": @"arrow.uturn.backward"},
             @{@"title": @"History", @"sel": @"showHistory:", @"keys": @"⌘Y", @"symbol": @"clock.arrow.circlepath"},
             @{@"title": @"Bookmarks", @"sel": @"showBookmarks:", @"keys": @"⌥⌘B", @"symbol": @"book"},
             @{@"title": @"Bookmark This Page", @"sel": @"toggleBookmark:", @"keys": @"⌘D", @"symbol": @"star"},
             @{@"title": @"Downloads", @"sel": @"showDownloadManager:", @"keys": @"⌥⌘L", @"symbol": @"arrow.down.circle"},
             @{@"title": @"Settings", @"sel": @"showSettings:", @"keys": @"⌘,", @"symbol": @"gearshape"},
             @{@"title": @"Reader", @"sel": @"toggleReader:", @"keys": @"⌃⌘R", @"symbol": @"doc.plaintext"},
             @{@"title": @"Picture in Picture", @"sel": @"pictureInPicture:", @"keys": @"⌃⌘P", @"symbol": @"pip"},
             @{@"title": @"Mute Tab", @"sel": @"muteCurrent:", @"keys": @"⌃⌘M", @"symbol": @"speaker.slash"},
             @{@"title": @"Find on Page", @"sel": @"showFind:", @"keys": @"⌘F", @"symbol": @"text.magnifyingglass"},
             @{@"title": @"Export as PDF", @"sel": @"exportPDF:", @"keys": @"", @"symbol": @"doc.richtext"},
             @{@"title": @"Share Page", @"sel": @"sharePage:", @"keys": @"", @"symbol": @"square.and.arrow.up"},
             @{@"title": @"Toggle Sidebar", @"sel": @"toggleSidebar:", @"keys": @"⌘S", @"symbol": @"sidebar.left"},
             @{@"title": @"Split View", @"sel": @"toggleSplit:", @"keys": @"⌃⌘S", @"symbol": @"rectangle.split.2x1"},
             @{@"title": @"Close Other Tabs", @"sel": @"closeOtherTabs:", @"keys": @"⌥⌘W", @"symbol": @"xmark.square"},
             @{@"title": @"Move Tab to New Window", @"sel": @"moveCurrentToNewWindow:", @"keys": @"", @"symbol": @"rectangle.portrait.and.arrow.right"},
             @{@"title": @"Web Inspector", @"sel": @"showInspector:", @"keys": @"⌥⌘I", @"symbol": @"hammer"},
             @{@"title": @"View Page Source", @"sel": @"viewSource:", @"keys": @"⌥⌘U", @"symbol": @"chevron.left.forwardslash.chevron.right"},
             @{@"title": @"Clear Browsing Data", @"sel": @"clearBrowsingData:", @"keys": @"⇧⌘⌫", @"symbol": @"trash"}];
}
static NSArray *MatchCommands(NSString *q, NSUInteger limit) {
    q = Trim(q.lowercaseString);
    BOOL all = [q hasPrefix:@">"];
    if (all) q = Trim([q substringFromIndex:1]);
    NSMutableArray *out = [NSMutableArray array];
    if (!all && q.length < 2) return out;
    NSArray *words = [q componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for (NSDictionary *c in StrikeCommands()) {
        NSString *t = [c[@"title"] lowercaseString];
        NSArray *tw = [t componentsSeparatedByString:@" "];
        BOOL ok = YES;
        for (NSString *w in words) {
            if (!w.length) continue;
            BOOL hit = NO; for (NSString *x in tw) if ([x hasPrefix:w]) hit = YES;
            if (!hit) { ok = NO; break; }
        }
        if (ok) { NSMutableDictionary *d = [c mutableCopy]; d[@"kind"] = @"command"; [out addObject:d]; }
        if (out.count >= limit) break;
    }
    return out;
}

- (NSArray *)suggestionsFor:(NSString *)text {
    if ([Trim(text) hasPrefix:@">"]) return MatchCommands(text, 30);
    NSMutableArray *out = [NSMutableArray array];
    NSURL *u = URLFromInput(text);
    BOOL isSearch = u && [u.absoluteString hasPrefix:[[Engine()[1] componentsSeparatedByString:@"%@"] firstObject]];
    NSString *done = self.completion;
    if (done.length) [out addObject:@{@"kind": @"url", @"title": done, @"url": done, @"detail": @"Go to site"}];
    else if (isSearch) [out addObject:@{@"kind": @"search", @"title": text, @"detail": [NSString stringWithFormat:@"Search with %@", Engine()[0]]}];
    else [out addObject:@{@"kind": @"url", @"title": text, @"url": text, @"detail": @"Go to site"}];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *q = text.lowercaseString;
    for (NSDictionary *b in VBookmarks.shared.allURLs) {
        if ([[b[@"name"] lowercaseString] containsString:q] || [[b[@"url"] lowercaseString] containsString:q]) {
            [out addObject:@{@"kind": @"url", @"title": [b[@"name"] length] ? b[@"name"] : b[@"url"], @"url": b[@"url"], @"detail": @"Bookmark"}];
            [seen addObject:b[@"url"]];
            if (out.count >= 3) break;
        }
    }
    for (NSDictionary *e in [[VHistory forProfile:self.profile] match:text limit:8]) {
        if ([seen containsObject:e[@"u"]]) continue;
        NSURL *eu = [NSURL URLWithString:e[@"u"]];
        NSString *bare = [[eu.host ?: @"" stringByAppendingString:eu.path ?: @""] stringByReplacingOccurrencesOfString:@"www." withString:@""];
        [out addObject:@{@"kind": @"url", @"title": [e[@"ti"] length] ? e[@"ti"] : bare, @"url": e[@"u"], @"detail": bare}];
        if (out.count >= 8) break;
    }
    // open tabs: switch instead of opening a duplicate
    NSUInteger tabsAdded = 0;
    for (VTab *t in self.tabs) {
        if (t == self.current || t.isHome || !t.url) continue;
        if ([[t.title lowercaseString] containsString:q] || [[t.url lowercaseString] containsString:q]) {
            [out insertObject:@{@"kind": @"tab", @"title": t.title.length ? t.title : t.url, @"url": t.url, @"detail": @"Switch to tab", @"tab": t} atIndex:MIN(out.count, 1 + tabsAdded)];
            if (++tabsAdded >= 2) break;
        }
    }
    NSArray *cmds = MatchCommands(text, 3);
    if (cmds.count) {   // after tabs, before history
        NSUInteger at = 1; while (at < out.count && [out[at][@"kind"] isEqualToString:@"tab"]) at++;
        [out insertObjects:cmds atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at, cmds.count)]];
    }
    if (!isSearch && !done.length) [out addObject:@{@"kind": @"search", @"title": text, @"detail": [NSString stringWithFormat:@"Search with %@", Engine()[0]]}];
    for (NSString *s in self.netSuggestions[q] ?: @[]) {
        if ([s.lowercaseString isEqualToString:q] || out.count >= 11) continue;
        [out addObject:@{@"kind": @"search", @"title": s, @"detail": @""}];
    }
    return out;
}

// Search suggestions come from the search engine you chose (and only it), after a short pause in typing.
- (void)fetchSuggestions:(NSString *)text {
    if (![Defaults() boolForKey:kSuggestNet] || text.length < 2 || [text containsString:@"://"]) return;
    NSString *engine = Engine()[0];
    NSString *enc = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    enc = [enc stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
    NSDictionary *ends = @{@"DuckDuckGo": @"https://duckduckgo.com/ac/?type=list&q=%@", @"Brave Search": @"https://search.brave.com/api/suggest?q=%@",
                           @"Google": @"https://suggestqueries.google.com/complete/search?client=firefox&q=%@", @"Ecosia": @"https://ac.ecosia.org/autocomplete?type=list&q=%@",
                           @"Bing": @"https://api.bing.com/osjson.aspx?query=%@", @"Startpage": @"https://www.startpage.com/osuggestions?q=%@"};
    NSString *fmt = ends[engine]; if (!fmt) return;
    NSString *q = text.lowercaseString;
    if (!self.netSuggestions) self.netSuggestions = [NSMutableDictionary dictionary];
    if (self.netSuggestions[q]) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startSuggestFetch:) object:nil];
    [self performSelector:@selector(startSuggestFetch:) withObject:@[[NSString stringWithFormat:fmt, enc], q] afterDelay:0.12];
}
- (void)startSuggestFetch:(NSArray *)a {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:a[0]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];
    r.HTTPShouldHandleCookies = NO;   // suggestions are anonymous
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSMutableArray *list = [NSMutableArray array];
        if ([j isKindOfClass:NSArray.class] && [j count] >= 2 && [j[1] isKindOfClass:NSArray.class]) { for (id s in j[1]) if ([s isKindOfClass:NSString.class]) [list addObject:s]; }
        else if ([j isKindOfClass:NSArray.class]) { for (NSDictionary *o in j) if ([o isKindOfClass:NSDictionary.class] && o[@"phrase"]) [list addObject:o[@"phrase"]]; }
        else if ([j isKindOfClass:NSDictionary.class] && [j[@"suggestions"] isKindOfClass:NSArray.class]) { for (id s in j[@"suggestions"]) if ([s isKindOfClass:NSString.class]) [list addObject:s]; }
        if (list.count > 5) [list removeObjectsInRange:NSMakeRange(5, list.count - 5)];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.netSuggestions[a[1]] = list;
            NSTextField *tf = self.typingField ?: self.toolbar.field;
            NSString *typed = Trim(self.completion ? [tf.stringValue substringToIndex:MIN(self.lastTyped, tf.stringValue.length)] : tf.stringValue);
            if (tf.currentEditor && [typed.lowercaseString isEqualToString:a[1]] && self.suggest.isVisible) {
                NSInteger sel = self.suggest.sel;
                [self.suggest showBelow:[self suggestAnchorFor:tf] items:[self suggestionsFor:typed]];
                self.suggest.sel = sel; [self.suggest.contentView setNeedsDisplay:YES];
            }
        });
    }] resume];
}

- (void)useSuggestion:(NSDictionary *)it newTab:(BOOL)nt {
    [self.suggest dismiss];
    if ([it[@"kind"] isEqualToString:@"tab"] && [self.tabs containsObject:it[@"tab"]]) { [self selectTab:it[@"tab"]]; return; }
    if ([it[@"kind"] isEqualToString:@"command"]) {
        [self.window makeFirstResponder:self.current.web ? (NSResponder *)self.current.web : self.window.contentView];
        [self refreshChrome];
        SEL a = NSSelectorFromString(it[@"sel"]);
        if (![NSApp sendAction:a to:nil from:self]) [NSApp sendAction:a to:gApp from:self];
        return;
    }
    NSString *target = it[@"url"] ?: it[@"title"];
    NSURL *u = [it[@"kind"] isEqualToString:@"search"] ? SearchURL(it[@"title"]) : URLFromInput(target);
    if (!u) return;
    if (nt) [self openURL:u newTab:YES]; else [self openURL:u newTab:NO];
}

// Inline completion: typing "you" fills in "youtube.com" with the rest selected.
- (void)autocomplete:(NSTextField *)f {
    NSText *ed = f.currentEditor;
    NSString *typed = f.stringValue;
    self.completion = nil;
    if (typed.length <= self.lastTyped || [typed containsString:@" "] || typed.length < 2) { self.lastTyped = typed.length; return; }
    self.lastTyped = typed.length;
    NSString *q = typed.lowercaseString;
    for (NSDictionary *e in [[VHistory forProfile:self.profile] match:typed limit:6]) {
        NSString *h = HostOf([NSURL URLWithString:e[@"u"]]);
        if ([h hasPrefix:q] && h.length > q.length) {
            self.completion = h;
            f.stringValue = [typed stringByAppendingString:[h substringFromIndex:typed.length]];
            ed.selectedRange = NSMakeRange(typed.length, h.length - typed.length);
            return;
        }
    }
}

- (BOOL)isAddressField:(id)f { return f && (f == self.toolbar.field || f == self.home.field); }
- (NSRect)suggestAnchorFor:(NSTextField *)f {
    if (f == self.home.field && self.home.window) return [self.window convertRectToScreen:[self.home convertRect:self.home.strike toView:nil]];
    VToolbar *tb = self.toolbar;
    return [self.window convertRectToScreen:[tb convertRect:tb.pill toView:nil]];
}
- (void)controlTextDidBeginEditing:(NSNotification *)n { if (n.object == self.home.field) self.home.needsDisplay = YES; }
- (void)controlTextDidChange:(NSNotification *)n {
    NSTextField *f = n.object;
    if (f == self.findBar.field) { [self find:NO restart:YES]; return; }
    if (![self isAddressField:f]) return;
    self.typingField = f;
    [self autocomplete:f];
    NSString *typed = self.completion ? [f.stringValue substringToIndex:MIN(self.lastTyped, f.stringValue.length)] : f.stringValue;
    if (!Trim(typed).length) { [self.suggest dismiss]; return; }
    [self.suggest showBelow:[self suggestAnchorFor:f] items:[self suggestionsFor:Trim(typed)]];
    [self fetchSuggestions:Trim(typed)];
}

- (void)controlTextDidEndEditing:(NSNotification *)n {
    if (![self isAddressField:n.object]) return;
    if (n.object == self.home.field) self.home.needsDisplay = YES;
    self.lastTyped = 0; self.completion = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self.suggest dismiss]; [self refreshChrome]; });
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (c == self.findBar.field) {
        if (sel == @selector(cancelOperation:)) { [self closeFind:nil]; return YES; }
        if (sel == @selector(insertNewline:)) { [self find:(NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0 restart:NO]; return YES; }
        return NO;
    }
    if (![self isAddressField:c]) return NO;
    NSTextField *af = (NSTextField *)c;
    if (sel == @selector(moveDown:) || sel == @selector(moveUp:)) {
        if (!self.suggest.isVisible) return NO;
        [self.suggest move:sel == @selector(moveDown:) ? 1 : -1];
        return YES;
    }
    if (sel == @selector(insertNewline:) || sel == @selector(insertNewlineIgnoringFieldEditor:)) {
        NSDictionary *it = self.suggest.isVisible && self.suggest.sel > 0 ? self.suggest.selected : nil;
        BOOL nt = (NSApp.currentEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) != 0;   // ⌘↩ or ⌥↩: new tab
        if (it) { [self useSuggestion:it newTab:nt]; return YES; }
        NSString *target = self.completion ?: af.stringValue;
        if (af == self.home.field) af.stringValue = @"";
        [self.suggest dismiss];
        if (nt) [self openURL:URLFromInput(target) newTab:YES]; else [self go:target];
        return YES;
    }
    if (sel == @selector(cancelOperation:)) {
        [self.suggest dismiss];
        if (self.current.web) [self.current.web focus]; else [self.window makeFirstResponder:nil];
        [self refreshChrome];
        return YES;
    }
    if (sel == @selector(deleteBackward:)) self.lastTyped = NSUIntegerMax;
    return NO;
}

#pragma mark Toolbar and menu actions

- (void)goBack:(id)s { [self.current.web goBack]; }
- (void)goForward:(id)s { [self.current.web goForward]; }
- (void)reloadOrStop:(id)s { VPage *w = self.current.web; if (w.loading) [w stop]; else [w reload]; }
- (void)hardReload:(id)s { [self.current.web hardReload]; }
- (void)printPage:(id)s { [self.current.web print]; }
- (void)stopLoading:(id)s { [self.current.web stop]; }
- (void)toggleSidebar:(id)s { [Defaults() setBool:![Defaults() boolForKey:kSidebarHidden] forKey:kSidebarHidden]; [self layout]; }
- (void)toggleBookmarksBar:(id)s { [Defaults() setBool:![Defaults() boolForKey:kShowBookmarks] forKey:kShowBookmarks]; [self layout]; }
- (void)newTabAction:(id)s { [self newTab:nil select:YES]; }
- (void)openLocation:(id)s { [self focusAddress]; }
- (void)closeTabAction:(id)s {
    NSWindow *k = NSApp.keyWindow;
    if (k && k != self.window && !k.isSheet) { [k performClose:nil]; return; }   // ⌘W closes Settings and other windows, like everywhere on macOS
    if (self.current) [self closeTab:self.current];
}
- (void)reopenClosed:(id)s {
    NSDictionary *d = [s isKindOfClass:NSMenuItem.class] && [[s representedObject] isKindOfClass:NSDictionary.class] ? [s representedObject] : self.closed.lastObject;
    if (!d) return;
    [self.closed removeObjectIdenticalTo:d];
    VTab *t = [VTab new]; t.owner = self;
    t.url = d[@"url"]; t.title = d[@"title"]; t.savedState = d[@"state"];
    if ([d[@"mediaKey"] isKindOfClass:NSString.class]) { t.mediaKey = d[@"mediaKey"]; t.mediaTime = t.savedMedia = t.resumeAt = [d[@"mediaTime"] doubleValue]; }
    t.favicon = [VFavicons.shared iconForURL:t.url];
    NSUInteger at = self.current ? [self.tabs indexOfObject:self.current] + 1 : self.tabs.count;
    [self.tabs insertObject:t atIndex:MIN(at, self.tabs.count)];
    [self selectTab:t];
}
- (void)nextTab:(id)s { [self cycle:1]; }
- (void)previousTab:(id)s { [self cycle:-1]; }
- (void)cycle:(NSInteger)d {
    if (self.tabs.count < 2) return;
    NSInteger i = (NSInteger)[self.tabs indexOfObject:self.current];
    [self selectTab:self.tabs[(NSUInteger)((i + d + (NSInteger)self.tabs.count) % (NSInteger)self.tabs.count)]];
}
- (void)selectTabNumber:(NSMenuItem *)m {
    NSInteger n = m.tag;
    if (!self.tabs.count) return;
    [self selectTab:n >= 9 ? self.tabs.lastObject : self.tabs[(NSUInteger)MIN(n - 1, (NSInteger)self.tabs.count - 1)]];
}
- (void)pinCurrent:(id)s { if (self.current) [self togglePin:self.current]; }
- (void)duplicateCurrent:(id)s { if (self.current.url && !self.current.isHome) [self newTab:[NSURL URLWithString:self.current.url] select:YES]; }

- (void)toggleBookmark:(id)s {
    VTab *t = self.current; if (!t.url || t.isHome) return;
    [VBookmarks.shared toggle:t.url title:t.title];
    if (t.favicon) [VFavicons.shared remember:t.favicon forURL:t.url];
    [self.bookmarksBar reload]; [self refreshChrome];
    [self showToast:[VBookmarks.shared find:t.url] ? @"Bookmarked" : @"Bookmark removed"];
}
- (void)openBookmarkItem:(NSMenuItem *)m { [self openURL:[NSURL URLWithString:m.representedObject] newTab:(NSApp.currentEvent.modifierFlags & NSEventModifierFlagCommand) != 0]; }
- (void)openBookmarkInNewTab:(NSMenuItem *)m { [self openURL:[NSURL URLWithString:m.representedObject] newTab:YES]; }
- (void)openAllBookmarks:(NSMenuItem *)m { for (NSString *u in m.representedObject) [self newTab:[NSURL URLWithString:u] select:NO]; }
- (void)copyText:(NSMenuItem *)m { [self copyString:m.representedObject]; }
- (void)copyString:(NSString *)s { if (!s) return; [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString]; [self showToast:@"Link copied"]; }
static BOOL RemoveNode(NSMutableArray *list, id n) {
    if ([list indexOfObjectIdenticalTo:n] != NSNotFound) { [list removeObjectIdenticalTo:n]; return YES; }
    for (NSMutableDictionary *x in list) if ([x[@"children"] isKindOfClass:NSMutableArray.class] && RemoveNode(x[@"children"], n)) return YES;
    return NO;
}
- (void)editBookmark:(NSMenuItem *)m {
    NSMutableDictionary *n = m.representedObject;
    NSAlert *a = [NSAlert new]; a.messageText = n[@"children"] ? @"Edit folder" : @"Edit bookmark";
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, n[@"children"] ? 26 : 58)];
    NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, n[@"children"] ? 0 : 32, 320, 24)]; name.stringValue = n[@"name"] ?: @""; name.placeholderString = @"Name";
    NSTextField *url = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)]; url.stringValue = n[@"url"] ?: @""; url.placeholderString = @"Address";
    [box addSubview:name]; if (!n[@"children"]) [box addSubview:url];
    a.accessoryView = box; [a addButtonWithTitle:@"Save"]; [a addButtonWithTitle:@"Cancel"];
    a.window.initialFirstResponder = name;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        n[@"name"] = name.stringValue;
        if (!n[@"children"]) { NSURL *u = URLFromInput(url.stringValue); if (u) n[@"url"] = u.absoluteString; }
        [VBookmarks.shared save]; [self.bookmarksBar reload]; [self refreshChrome];
    }];
}
- (void)newBookmarkFolder:(NSMenuItem *)m {
    NSAlert *a = [NSAlert new]; a.messageText = @"New folder";
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)]; f.placeholderString = @"Folder name"; a.accessoryView = f;
    [a addButtonWithTitle:@"Create"]; [a addButtonWithTitle:@"Cancel"]; a.window.initialFirstResponder = f;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn || !Trim(f.stringValue).length) return;
        NSMutableDictionary *folder = [@{@"name": Trim(f.stringValue), @"children": [NSMutableArray array]} mutableCopy];
        NSMutableDictionary *after = m.representedObject;
        NSUInteger i = after ? [VBookmarks.shared.bar indexOfObjectIdenticalTo:after] : NSNotFound;
        if (i == NSNotFound) [VBookmarks.shared.bar addObject:folder]; else [VBookmarks.shared.bar insertObject:folder atIndex:i + 1];
        [VBookmarks.shared save]; [self.bookmarksBar reload];
    }];
}
- (void)deleteBookmark:(NSMenuItem *)m {
    NSMutableDictionary *n = m.representedObject;
    BMRemove(VBookmarks.shared.bar, n);
    [VBookmarks.shared save]; [self.bookmarksBar reload]; [self refreshChrome];
}

- (void)siteMenu:(id)s {
    VTab *t = self.current;
    if (t.isHome) { [self focusAddress]; return; }
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSURL *u = [NSURL URLWithString:t.url ?: @""];
    [m addItemWithTitle:HostOf(u) action:nil keyEquivalent:@""].enabled = NO;
    [m addItemWithTitle:[u.scheme isEqualToString:@"https"] ? @"Connection is secure" : @"Connection is not secure" action:nil keyEquivalent:@""].enabled = NO;
    [m addItemWithTitle:@"Rendered by WebKit (Safari's engine)" action:nil keyEquivalent:@""].enabled = NO;
    NSString *host = HostOf(u);
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *js = [m addItemWithTitle:@"JavaScript on This Site" action:@selector(toggleSiteScripts:) keyEquivalent:@""]; js.target = self; js.representedObject = host;
    js.state = [Defaults() boolForKey:kScripts] && ![[Defaults() arrayForKey:kJSOff] containsObject:host] ? NSControlStateValueOn : NSControlStateValueOff;
    NSDictionary *perms = [Defaults() dictionaryForKey:kSitePerms][host];
    for (NSString *k in @[@"camera", @"microphone"]) {
        NSInteger v = [perms[k] integerValue];
        NSMenuItem *pi = [m addItemWithTitle:[NSString stringWithFormat:@"%@: %@", k.capitalizedString, v == 1 ? @"Allowed" : v == 2 ? @"Blocked" : @"Ask"] action:nil keyEquivalent:@""];
        NSMenu *sub = [[NSMenu alloc] initWithTitle:k];
        for (NSInteger opt = 0; opt < 3; opt++) {
            NSMenuItem *o = [sub addItemWithTitle:@[@"Ask", @"Allow", @"Block"][(NSUInteger)opt] action:@selector(setSitePermission:) keyEquivalent:@""];
            o.target = self; o.representedObject = @[host, k, @(opt)]; o.state = opt == v ? NSControlStateValueOn : NSControlStateValueOff;
        }
        pi.submenu = sub;
    }
    NSNumber *z = [Defaults() dictionaryForKey:kZoom][host];
    if (z) { NSMenuItem *zi = [m addItemWithTitle:[NSString stringWithFormat:@"Zoom: %d%% (Reset)", (int)round(z.doubleValue * 100)] action:@selector(zoomReset:) keyEquivalent:@""]; zi.target = self; }
    NSMenuItem *cl = [m addItemWithTitle:@"Clear Cookies and Data for This Site…" action:@selector(clearSiteData:) keyEquivalent:@""]; cl.target = self; cl.representedObject = host;
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *c = [m addItemWithTitle:@"Copy Link" action:@selector(copyText:) keyEquivalent:@""]; c.target = self; c.representedObject = u.absoluteString;
    VButton *btn = self.toolbar.infoBtn;
    PopMenu(m, NSMakePoint(0, NSHeight(btn.bounds) + 6), btn);
}

- (void)toggleSiteScripts:(NSMenuItem *)m {
    NSString *h = m.representedObject; if (!h.length) return;
    if (![Defaults() boolForKey:kScripts]) { [Defaults() setBool:YES forKey:kScripts]; }
    NSMutableArray *a = [[Defaults() arrayForKey:kJSOff] ?: @[] mutableCopy];
    if ([a containsObject:h]) [a removeObject:h]; else [a addObject:h];
    [Defaults() setObject:a forKey:kJSOff];
    [self showToast:[a containsObject:h] ? [NSString stringWithFormat:@"JavaScript off for %@", h] : [NSString stringWithFormat:@"JavaScript on for %@", h]];
    [self.current.web reload];
}
- (void)setSitePermission:(NSMenuItem *)m {
    NSArray *a = m.representedObject;
    NSMutableDictionary *all = [[Defaults() dictionaryForKey:kSitePerms] ?: @{} mutableCopy];
    NSMutableDictionary *mine = [all[a[0]] ?: @{} mutableCopy];
    if ([a[2] integerValue] == 0) [mine removeObjectForKey:a[1]]; else mine[a[1]] = a[2];
    if (mine.count) all[a[0]] = mine; else [all removeObjectForKey:a[0]];
    [Defaults() setObject:all forKey:kSitePerms];
}
- (void)clearSiteData:(NSMenuItem *)m {
    NSString *h = m.representedObject; if (!h.length) return;
    NSAlert *al = [NSAlert new]; al.messageText = [NSString stringWithFormat:@"Clear cookies and data for %@?", h];
    al.informativeText = @"You'll be signed out of this site."; [al addButtonWithTitle:@"Clear"]; [al addButtonWithTitle:@"Cancel"];
    [al beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        WKWebsiteDataStore *ds = self.isPrivate ? self.privateStore : ProfileStore(self.profile);
        [ds fetchDataRecordsOfTypes:WKWebsiteDataStore.allWebsiteDataTypes completionHandler:^(NSArray<WKWebsiteDataRecord *> *recs) {
            NSMutableArray *mine = [NSMutableArray array];
            for (WKWebsiteDataRecord *rec in recs) if ([rec.displayName isEqualToString:h] || [h hasSuffix:[@"." stringByAppendingString:rec.displayName]] || [rec.displayName hasSuffix:[@"." stringByAppendingString:h]]) [mine addObject:rec];
            [ds removeDataOfTypes:WKWebsiteDataStore.allWebsiteDataTypes forDataRecords:mine completionHandler:^{ [self showToast:[NSString stringWithFormat:@"Cleared data for %@", h]]; [self.current.web reload]; }];
        }];
    }];
}

- (void)shieldMenu:(id)s {
    VTab *t = self.current;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    BOOL on = [Defaults() boolForKey:kBlock];
    NSString *head = !on ? @"Blocking is off" : [NSString stringWithFormat:@"Blocking ads and trackers · %lu hosts", (unsigned long)gRuleCount];
    (void)t;
    [m addItemWithTitle:head action:nil keyEquivalent:@""].enabled = NO;
    [m addItemWithTitle:[@"Filter lists: " stringByAppendingString:VBlocker.shared.status] action:nil keyEquivalent:@""].enabled = NO;
    [m addItem:NSMenuItem.separatorItem];
    NSString *site = HostOf([NSURL URLWithString:t.url ?: @""]);
    if (on && site.length && !t.isHome) {
        BOOL allowed = [[Defaults() arrayForKey:kAllowlist] containsObject:site];
        NSMenuItem *si = [m addItemWithTitle:[NSString stringWithFormat:allowed ? @"Turn On Blocking for %@" : @"Turn Off Blocking for %@", site] action:@selector(toggleBlockingSite:) keyEquivalent:@""];
        si.target = self; si.representedObject = site;
    }
    if (site.length && !t.isHome && [t.url hasPrefix:@"http"]) {
        NSMenuItem *be = [m addItemWithTitle:@"Block Element on This Page…" action:@selector(blockElement:) keyEquivalent:@""]; be.target = self;
        NSString *key = [site hasPrefix:@"www."] ? [site substringFromIndex:4] : site;
        NSUInteger n = [[Defaults() dictionaryForKey:@"cosmeticFilters"][key] count];
        if (n) {
            NSMenuItem *ul = [m addItemWithTitle:@"Undo Last Blocked Element" action:@selector(undoLastElement:) keyEquivalent:@""]; ul.target = self; ul.representedObject = key;
            NSMenuItem *re = [m addItemWithTitle:[NSString stringWithFormat:@"Show All %lu Hidden Element%@ on %@", (unsigned long)n, n == 1 ? @"" : @"s", key] action:@selector(resetElements:) keyEquivalent:@""]; re.target = self; re.representedObject = key;
        }
        [m addItem:NSMenuItem.separatorItem];
    }
    NSMenuItem *g = [m addItemWithTitle:on ? @"Turn Off Blocking Everywhere" : @"Turn On Blocking" action:@selector(toggleBlockingGlobal:) keyEquivalent:@""]; g.target = self;
    NSMenuItem *u = [m addItemWithTitle:@"Update Filter Lists Now" action:@selector(updateListsNow:) keyEquivalent:@""]; u.target = self;
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *st = [m addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@""]; st.target = gApp;
    VButton *btn = self.toolbar.shieldBtn;
    PopMenu(m, NSMakePoint(0, NSHeight(btn.bounds) + 6), btn);
}

- (void)toggleBlockingGlobal:(id)s {
    BOOL on = ![Defaults() boolForKey:kBlock];
    [Defaults() setBool:on forKey:kBlock];
    FlintSetBlocking(on);
    [self.current.web reload];
    [self refreshChrome];
}
- (void)toggleBlockingSite:(NSMenuItem *)m {
    NSString *site = m.representedObject; if (!site.length) return;
    NSMutableArray *a = [[Defaults() arrayForKey:kAllowlist] ?: @[] mutableCopy];
    BOOL wasAllowed = [a containsObject:site];
    if (wasAllowed) [a removeObject:site]; else [a addObject:site];
    [Defaults() setObject:a forKey:kAllowlist];
    [self showToast:wasAllowed ? [NSString stringWithFormat:@"Blocking back on for %@…", site] : [NSString stringWithFormat:@"Blocking off for %@…", site]];
    VPage *w = self.current.web;
    FlintReloadBlocklistsThen(^{ [w reload]; });
}
- (void)updateListsNow:(id)s {
    [self showToast:@"Updating filter lists…"];
    [VBlocker.shared updateLists:YES done:^{ [self showToast:@"Filter lists updated"]; }];
}

- (void)mainMenu:(id)s {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *(^add)(NSString *, SEL, id) = ^NSMenuItem *(NSString *t, SEL a, id target) { NSMenuItem *i = [m addItemWithTitle:t action:a keyEquivalent:@""]; i.target = target; return i; };
    if (!self.isPrivate) {   // whose window this is, at the top: its avatar and name, opening the list of profiles
        NSMenuItem *pi = [m addItemWithTitle:ProfileName(self.profile) action:nil keyEquivalent:@""];
        pi.image = ProfileAvatar(self.profile, ProfileName(self.profile), 16);
        pi.submenu = [self profilesMenu];
        [m addItem:NSMenuItem.separatorItem];
    }
    add(@"New Tab", @selector(newTabAction:), self);
    add(@"Reopen Closed Tab", @selector(reopenClosed:), self).enabled = self.closed.count > 0;
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *hist = [m addItemWithTitle:@"History" action:nil keyEquivalent:@""];
    NSMenu *hm = [[NSMenu alloc] initWithTitle:@"History"];
    for (NSDictionary *e in [[VHistory forProfile:self.profile] recent:20]) {
        NSString *title = [e[@"ti"] length] ? e[@"ti"] : e[@"u"];
        if (title.length > 60) title = [[title substringToIndex:59] stringByAppendingString:@"…"];
        NSMenuItem *i = [hm addItemWithTitle:title action:@selector(openBookmarkItem:) keyEquivalent:@""];
        i.target = self; i.representedObject = e[@"u"];
        NSImage *ic = [VFavicons.shared iconForURL:e[@"u"]]; if (ic) { NSImage *sm = [ic copy]; sm.size = NSMakeSize(16, 16); i.image = sm; }
    }
    if (!hm.numberOfItems) [hm addItemWithTitle:@"Nothing yet" action:nil keyEquivalent:@""].enabled = NO;
    [hm addItem:NSMenuItem.separatorItem];
    NSMenuItem *all = [hm addItemWithTitle:@"Show All History" action:@selector(showHistory:) keyEquivalent:@"y"]; all.target = self;
    NSMenuItem *clr = [hm addItemWithTitle:@"Clear History…" action:@selector(clearBrowsingData:) keyEquivalent:@""]; clr.target = self;
    hist.submenu = hm;
    add(@"Bookmarks", @selector(showBookmarks:), self);
    add(@"Downloads", @selector(showDownloadManager:), self);
    add([Defaults() boolForKey:kShowBookmarks] ? @"Hide Bookmarks Bar" : @"Show Bookmarks Bar", @selector(toggleBookmarksBar:), self);
    [m addItem:NSMenuItem.separatorItem];
    VPage *w = self.current.web;
    if (w) {
        [m addItemWithTitle:[NSString stringWithFormat:@"Zoom  %d%%", (int)round(w.zoom * 100)] action:nil keyEquivalent:@""].enabled = NO;
        add(@"Zoom In", @selector(zoomIn:), self); add(@"Zoom Out", @selector(zoomOut:), self); add(@"Actual Size", @selector(zoomReset:), self);
        add(@"Find on Page…", @selector(showFind:), self);
        add(@"Save Page to Downloads", @selector(savePage:), self);
        add(@"View Page Source", @selector(viewSource:), self);
        add(@"Open in Default Browser", @selector(openInDefaultBrowser:), self).representedObject = w.url;
        [m addItem:NSMenuItem.separatorItem];
    }
    NSArray *exts = FExtHost.shared.extensions;
    if (exts.count) {
        NSMenuItem *em = [m addItemWithTitle:@"Extensions" action:nil keyEquivalent:@""];
        NSMenu *sub = [[NSMenu alloc] initWithTitle:@"Extensions"];
        for (id e in exts) { NSMenuItem *i = [sub addItemWithTitle:[e valueForKey:@"name"] action:@selector(openExtension:) keyEquivalent:@""]; i.target = self; i.representedObject = e; }
        [sub addItem:NSMenuItem.separatorItem];
        NSMenuItem *f = [sub addItemWithTitle:@"Show Extensions Folder" action:@selector(showExtensions:) keyEquivalent:@""]; f.target = gApp;
        em.submenu = sub;
    } else add(@"Extensions Folder…", @selector(showExtensions:), gApp);
    add(@"Settings…", @selector(showSettings:), gApp);
    VButton *btn = self.toolbar.menuBtn;
    PopMenuRight(m, NSMakePoint(NSWidth(btn.bounds), NSHeight(btn.bounds) + 6), btn);
}

- (void)openExtension:(NSMenuItem *)m { [FExtHost.shared openPopup:m.representedObject from:self.toolbar.menuBtn]; }

// A page that already exists (a popup the site opened) gets its own tab.
- (void)newTabWithPage:(VPage *)p url:(NSURL *)u select:(BOOL)sel {
    VTab *t = [VTab new]; t.owner = self;
    t.url = u.absoluteString; t.title = u.host ?: @"New Tab";
    p.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    p.tab = t; t.web = p;
    NSUInteger at = self.current ? [self.tabs indexOfObject:self.current] + 1 : self.tabs.count;
    [self.tabs insertObject:t atIndex:MIN(at, self.tabs.count)];
    if (sel) [self selectTab:t]; else { t.hiddenAt = NSDate.date.timeIntervalSince1970; [self refreshChrome]; }
    [self.sidebar reload];
    [self scheduleSave];
}

- (void)openLinkInBackground:(NSMenuItem *)m { [self newTab:[NSURL URLWithString:m.representedObject] select:NO]; [self showToast:@"Opened in a background tab"]; }
- (void)bookmarkURL:(NSMenuItem *)m {
    NSString *u = m.representedObject; if (!u) return;
    if (![VBookmarks.shared find:u]) [VBookmarks.shared toggle:u title:HostOf([NSURL URLWithString:u])];
    [self.bookmarksBar reload]; [self showToast:@"Bookmarked"];
}
- (void)searchFor:(NSMenuItem *)m { NSURL *u = URLFromInput(m.representedObject); if (u) [self newTab:u select:YES]; }
- (void)openInDefaultBrowser:(NSMenuItem *)m {
    NSString *u = [m isKindOfClass:NSMenuItem.class] ? m.representedObject : nil; u = u ?: self.current.url;
    if (u) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:u]];
}
- (void)viewSource:(id)s {
    NSString *u = self.current.url; if (!u.length || self.current.isHome) return;
    [self newTab:[NSURL URLWithString:[@"view-source:" stringByAppendingString:u]] select:YES];
}
- (NSURL *)downloadFolder {
    NSString *d = [Defaults() stringForKey:kDownloadDir];
    return d.length ? [NSURL fileURLWithPath:d] : [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
}
/// Save a file into the download folder (or ask where, if that's the setting), under a name that doesn't clash.
- (void)saveData:(NSData *)data name:(NSString *)name {
    NSString *base = name.length ? name : @"download";
    void (^write)(NSURL *) = ^(NSURL *dest) {
        if ([data writeToURL:dest atomically:YES]) [self showToast:[NSString stringWithFormat:@"Saved %@", dest.lastPathComponent]];
        else [self showToast:@"Couldn't save the file"];
    };
    if ([Defaults() boolForKey:kAskDownload]) {
        NSSavePanel *p = [NSSavePanel savePanel]; p.nameFieldStringValue = base; p.directoryURL = self.downloadFolder;
        [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { if (r == NSModalResponseOK) write(p.URL); }];
        return;
    }
    NSURL *dir = self.downloadFolder;
    NSURL *dest = [dir URLByAppendingPathComponent:base];
    for (int n = 1; [NSFileManager.defaultManager fileExistsAtPath:dest.path]; n++)
        dest = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d%@", base.stringByDeletingPathExtension, n, base.pathExtension.length ? [@"." stringByAppendingString:base.pathExtension] : @""]];
    write(dest);
}
- (void)downloadURL:(NSMenuItem *)m {
    NSURL *u = [NSURL URLWithString:m.representedObject]; if (!u) return;
    if (self.current.web) { [self.current.web download:u.absoluteString]; return; }   // Chromium's downloader keeps your sign-in
    [self showToast:@"Downloading…"];
    [[NSURLSession.sharedSession dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!d || e) { [self showToast:@"Download failed"]; return; }
            [self saveData:d name:r.suggestedFilename ?: u.lastPathComponent];
        });
    }] resume];
}
- (void)savePage:(id)s {
    VPage *w = self.current.web; if (!w) return;
    NSString *title = [[self.current.title ?: @"page" componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"]] componentsJoinedByString:@"-"];
    [w source:^(NSString *src) {
        if (src.length) [self saveData:[src dataUsingEncoding:NSUTF8StringEncoding] name:[title stringByAppendingPathExtension:@"html"]];
    }];
}

- (void)openDownloads:(id)s {
    [NSWorkspace.sharedWorkspace openURL:self.downloadFolder];
}
- (void)clearBrowsingData:(id)s {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Clear history?";
    a.informativeText = @"This removes your browsing history and address-bar suggestions. Bookmarks and tabs stay.";
    [a addButtonWithTitle:@"Clear"]; [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        [[VHistory forProfile:self.profile] clear];
        [self showToast:@"History cleared"];
    }];
}

- (void)setZoom:(CGFloat)z {
    VPage *w = self.current.web; if (!w) return;
    z = MAX(0.3, MIN(3, z));
    [w setZoomLevel:z];
    NSMutableDictionary *d = [[Defaults() dictionaryForKey:kZoom] ?: @{} mutableCopy];
    NSString *h = HostOf([NSURL URLWithString:w.url ?: @""]);
    if (fabs(z - 1) < 0.01) [d removeObjectForKey:h]; else if (h.length) d[h] = @(z);
    [Defaults() setObject:d forKey:kZoom];
    [self showToast:[NSString stringWithFormat:@"Zoom %d%%", (int)round(z * 100)]];
}
- (void)zoomIn:(id)s { [self setZoom:self.current.web.zoom + 0.1]; }
- (void)zoomOut:(id)s { [self setZoom:self.current.web.zoom - 0.1]; }
- (void)zoomReset:(id)s { [self setZoom:1]; }

#pragma mark Find

- (void)showFind:(id)s {
    if (!self.current.web) return;
    self.findBar.hidden = NO;
    [self.content addSubview:self.findBar];
    [self.window makeFirstResponder:self.findBar.field];
    [self.findBar.field.currentEditor selectAll:nil];
}
- (void)closeFind:(id)s {
    self.findBar.hidden = YES; [self.findBar removeFromSuperview];
    [self.current.web stopFind];
    if (self.current.web) [self.current.web focus];
}
- (void)find:(BOOL)backwards restart:(BOOL)restart {
    VPage *w = self.current.web; NSString *q = self.findBar.field.stringValue;
    if (!w || !q.length) { [w stopFind]; self.findBar.result.stringValue = @""; return; }
    [w find:q forward:!backwards next:!restart];
}
- (void)findCount:(int)count active:(int)active {
    if (self.findBar.hidden) return;
    self.findBar.result.stringValue = count <= 0 ? @"No matches" : active < 0 ? [NSString stringWithFormat:@"%d match%@", count, count == 1 ? @"" : @"es"] : [NSString stringWithFormat:@"%d of %d", active, count];
    self.findBar.result.textColor = count > 0 ? vFaint : HexA(0xe57373, 1);
}

#pragma mark Toast

- (void)showToast:(NSString *)s {
    NSTextField *t = self.toast;
    t.stringValue = [NSString stringWithFormat:@"   %@   ", s];
    [t sizeToFit];
    NSSize sz = NSMakeSize(MAX(120, NSWidth(t.frame) + 10), 30);
    t.frame = NSMakeRect(round((NSWidth(self.content.bounds) - sz.width) / 2), NSHeight(self.content.bounds) - sz.height - 18, sz.width, sz.height);
    FacetView(t, 8, vLine);
    [self.content addSubview:t];
    t.alphaValue = 1;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
    [self performSelector:@selector(hideToast) withObject:nil afterDelay:2.2];
}
- (void)hideToast {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.3; self.toast.animator.alphaValue = 0; } completionHandler:^{ [self.toast removeFromSuperview]; }];
}

@end

#pragma mark - Page tools: reader, PDF, web archive, share, open file, inspector

// Pulls the main article out of a page (a small Readability-style pass), run in Flint's own world so
// the page can't interfere. Returns {title, byline, site, lang, dir, html, words}.
static NSString *ReaderExtractJS(void) {
    return @"const doc=document;const W=s=>(s||'').replace(/\\s+/g,' ').trim();"
    "const meta=n=>{const m=doc.querySelector('meta[property=\"'+n+'\"],meta[name=\"'+n+'\"]');return m?W(m.content):''};"
    "const junk=/(comment|share|social|related|promo|advert|^ad-|-ad$|\\bads?\\b|sponsor|newsletter|subscribe|signup|cookie|popup|modal|banner|breadcrumb|pagination|toolbar|sidebar|footer|masthead|byline-share|outbrain|taboola|recirc|more-from|read-next|paywall)/i;"
    "const textLen=e=>W(e.textContent).length;const linkLen=e=>{let n=0;for(const a of e.querySelectorAll('a'))n+=W(a.textContent).length;return n};"
    "let best=null,bestScore=0;const scores=new Map();"
    "for(const p of doc.querySelectorAll('p,pre,blockquote,td')){const t=W(p.textContent);if(t.length<40)continue;"
    "const s=1+t.split(',').length+Math.min(3,Math.floor(t.length/100));let e=p.parentElement,f=1;"
    "for(let i=0;e&&i<3;i++,e=e.parentElement,f/=2){scores.set(e,(scores.get(e)||0)+s*f)}}"
    "for(const [e,s0] of scores){const tl=textLen(e)||1;let s=s0*(1-linkLen(e)/tl);const idc=(e.id+' '+e.className);"
    "if(/article|content|post|story|entry|main|body|text/i.test(idc))s*=1.25;if(junk.test(idc))s*=.3;if(e.tagName==='ARTICLE'||e.tagName==='MAIN')s*=1.3;"
    "if(s>bestScore){bestScore=s;best=e}}"
    "const arts=[...doc.querySelectorAll('article')].filter(a=>textLen(a)>600).sort((a,b)=>textLen(b)-textLen(a));"
    "if(arts[0]&&(!best||arts[0].contains(best)||textLen(arts[0])>textLen(best)*.9))best=arts[0];"
    "if(!best||textLen(best)<250)return {error:'Flint couldn\\'t find an article on this page.'};"
    "const root=best.cloneNode(true);"
    "for(const img of root.querySelectorAll('img')){const real=img.getAttribute('data-src')||img.getAttribute('data-lazy-src')||img.getAttribute('data-original');if(real)img.setAttribute('src',real)}"
    "const live=best.querySelectorAll('img'),copy=root.querySelectorAll('img');copy.forEach((c,i)=>{const l=live[i];if(l&&l.currentSrc&&!/^data:/.test(l.currentSrc))c.setAttribute('src',l.currentSrc);"
    "try{c.setAttribute('src',new URL(c.getAttribute('src')||'',doc.baseURI).href)}catch(e){};c.removeAttribute('srcset')});"
    "for(const a of root.querySelectorAll('a[href]')){try{a.setAttribute('href',new URL(a.getAttribute('href'),doc.baseURI).href)}catch(e){}}"
    "root.querySelectorAll('script,style,noscript,iframe,object,embed,form,button,input,select,textarea,nav,aside,footer,svg,canvas,dialog,[hidden],[aria-hidden=true],[role=navigation],[role=complementary],[role=dialog]').forEach(e=>e.remove());"
    "const clutter=/(^|\\s)(hatnote|ambox|mbox-[a-z]+|metadata|navbox|vertical-navbox|infobox|sidebar|mw-editsection|noprint|shortdescription|reflist|toc|sistersitebox|mw-jump-link|printfooter|catlinks|reference|mw-empty-elt|portal|authority-control)(\\s|$)/;"
    "root.querySelectorAll('[class]').forEach(e=>{if(e.isConnected&&typeof e.className==='string'&&clutter.test(e.className))e.remove()});"
    "for(const e of [...root.querySelectorAll('div,section,ul,header,figure,span')]){if(!e.isConnected)continue;const idc=(e.id+' '+(typeof e.className==='string'?e.className:''));"
    "const tl=textLen(e);if(junk.test(idc)&&tl<800){e.remove();continue}if(tl&&linkLen(e)/tl>.65&&tl<500&&!e.querySelector('img')){e.remove()}}"
    "const h1t=W((doc.querySelector('h1')||{}).textContent),og=meta('og:title');const title=(h1t&&(!og||og.startsWith(h1t)||h1t.length>10))?h1t:(og||h1t||doc.title);"
    "const h=root.querySelector('h1');if(h&&W(h.textContent)===title)h.remove();"
    "const words=W(root.textContent).split(' ').length;"
    "return {title,byline:meta('author')||meta('article:author')||W((doc.querySelector('[rel=author],.author,.byline,[itemprop=author]')||{}).textContent).slice(0,120),"
    "site:meta('og:site_name')||location.hostname.replace(/^www\\./,''),lang:doc.documentElement.lang||'',dir:doc.dir||'',html:root.innerHTML,words,url:location.href,"
    "published:meta('article:published_time')||((doc.querySelector('time[datetime]')||{}).getAttribute?doc.querySelector('time[datetime]').getAttribute('datetime'):'')}";
}

// Peek: a floating look at a link over the current page. Esc or a click outside closes it; "Open in Tab" keeps it.
@interface VPeek : NSView
@property (strong) FWebView *web;
@property (strong) NSView *card;
@property (strong) NSTextField *label;
@property (weak) VWindow *owner;
@property (strong) id monitor;
@end
@implementation VPeek
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)d { [[NSColor colorWithWhite:0 alpha:ThemeIsLight() ? 0.25 : 0.5] setFill]; NSRectFillUsingOperation(d, NSCompositingOperationSourceOver); }
- (void)mouseDown:(NSEvent *)e { if (!NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.card.frame)) [self.owner closePeek:nil]; }
- (void)resizeSubviewsWithOldSize:(NSSize)o {
    NSRect b = self.bounds;
    CGFloat w = MIN(NSWidth(b) - 80, 1100), h = NSHeight(b) - 64;
    self.card.frame = NSMakeRect(round((NSWidth(b) - w) / 2), 32, w, h);
    self.label.frame = NSMakeRect(16, 10, w - 160, 18);
    for (NSView *v in self.card.subviews) if ([v isKindOfClass:VButton.class]) v.frame = NSMakeRect(v.tag == 1 ? w - 72 : w - 40, 4, 30, 28);
    self.web.frame = NSMakeRect(0, 36, w, h - 36);
}
@end

@implementation VWindow (Tools)
- (void)peekLink:(NSMenuItem *)m { NSURL *u = [NSURL URLWithString:m.representedObject ?: @""]; if (u) [self peekURL:u]; }
- (void)peekURL:(NSURL *)u {
    [self closePeek:nil];
    VPeek *pk = [[VPeek alloc] initWithFrame:self.content.bounds];
    pk.owner = self; pk.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; pk.identifier = @"peek";
    NSView *card = [[NSView alloc] initWithFrame:NSZeroRect]; card.wantsLayer = YES;
    card.layer.backgroundColor = vContentBg.CGColor; card.layer.cornerRadius = 12; card.layer.masksToBounds = YES;
    card.layer.borderWidth = 1; card.layer.borderColor = vLine.CGColor;
    NSView *head = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 4000, 36)]; head.wantsLayer = YES; head.layer.backgroundColor = vCard.CGColor;
    [card addSubview:head];
    pk.label = [NSTextField labelWithString:HostOf(u) ?: u.absoluteString];
    pk.label.font = UIFont(12.5, NSFontWeightMedium); pk.label.textColor = vDim; pk.label.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:pk.label];
    VButton *open = [VButton symbol:@"arrow.up.forward.square" size:13 tip:@"Open in tab" target:self action:@selector(adoptPeek:)]; open.tag = 1;
    VButton *close = [VButton symbol:@"xmark" size:11 tip:@"Close (esc)" target:self action:@selector(closePeek:)]; close.tag = 2;
    [card addSubview:open]; [card addSubview:close];
    pk.web = [[FWebView alloc] initWithFrame:NSZeroRect configuration:[self pageConfig]];
    pk.web.allowsBackForwardNavigationGestures = YES;
    if (@available(macOS 12.0, *)) pk.web.underPageBackgroundColor = vContentBg;
    [card addSubview:pk.web];
    pk.card = card; [pk addSubview:card];
    [self.content addSubview:pk];
    [pk resizeSubviewsWithOldSize:pk.bounds.size];
    [pk.web loadRequest:[NSURLRequest requestWithURL:u]];
    [self.window makeFirstResponder:pk.web];
    __weak VWindow *ws = self;
    pk.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        if (e.keyCode == 53 && e.window == ws.window) { [ws closePeek:nil]; return nil; }   // esc
        return e;
    }];
}
- (VPeek *)peekView { for (NSView *v in self.content.subviews) if ([v isKindOfClass:VPeek.class]) return (VPeek *)v; return nil; }
- (void)closePeek:(id)s {
    VPeek *pk = [self peekView]; if (!pk) return;
    if (pk.monitor) [NSEvent removeMonitor:pk.monitor];
    [pk.web stopLoading]; [pk removeFromSuperview];
    [self.current.web focus];
}
- (void)adoptPeek:(id)s {   // the peeked page becomes a real tab, history and all
    VPeek *pk = [self peekView]; if (!pk) return;
    FWebView *w = pk.web; NSURL *u = w.URL ?: [NSURL URLWithString:@"about:blank"];
    [w removeFromSuperview]; pk.web = nil;
    if (pk.monitor) [NSEvent removeMonitor:pk.monitor];
    [pk removeFromSuperview];
    VPage *p = [[VPage alloc] initWithFrame:self.content.bounds web:w];
    [self newTabWithPage:p url:u select:YES];
}

- (void)toggleReader:(id)s {
    VPage *p = self.current.web; if (!p) return;
    NSURL *u = p.web.URL;
    if ([u.scheme isEqualToString:@"flint"] && [u.host isEqualToString:@"reader"]) {   // already reading: back to the page
        if (p.web.canGoBack) [p.web goBack];
        else { NSString *orig = nil; for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO].queryItems) if ([q.name isEqualToString:@"u"]) orig = q.value; if (orig) [self openURL:[NSURL URLWithString:orig] newTab:NO]; }
        return;
    }
    if (![u.scheme hasPrefix:@"http"]) { [self showToast:@"Reader works on web articles"]; return; }
    [p.web callAsyncJavaScript:ReaderExtractJS() arguments:@{} inFrame:nil inContentWorld:[WKContentWorld worldWithName:@"flint"] completionHandler:^(id r, NSError *e) {
        if (![r isKindOfClass:NSDictionary.class] || r[@"error"]) { [self showToast:[r isKindOfClass:NSDictionary.class] ? r[@"error"] : @"Couldn't open Reader on this page"]; return; }
        if (!gReader) gReader = [NSMutableDictionary dictionary];
        if (gReader.count > 30) [gReader removeAllObjects];
        NSString *token = [NSUUID UUID].UUIDString;
        gReader[token] = r;
        NSURLComponents *c = [NSURLComponents componentsWithString:@"flint://reader/"];
        c.queryItems = @[[NSURLQueryItem queryItemWithName:@"id" value:token], [NSURLQueryItem queryItemWithName:@"u" value:u.absoluteString]];
        [p.web loadRequest:[NSURLRequest requestWithURL:c.URL]];
    }];
}

- (void)exportPDF:(id)s {
    VPage *p = self.current.web; if (!p) return;
    NSString *title = [[self.current.title ?: @"Page" componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"]] componentsJoinedByString:@"-"];
    [p.web createPDFWithConfiguration:nil completionHandler:^(NSData *d, NSError *e) {
        if (d.length) [self saveData:d name:[title stringByAppendingPathExtension:@"pdf"]]; else [self showToast:@"Couldn't make a PDF"];
    }];
}
- (void)saveWebArchive:(id)s {
    VPage *p = self.current.web; if (!p) return;
    NSString *title = [[self.current.title ?: @"Page" componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"]] componentsJoinedByString:@"-"];
    [p.web createWebArchiveDataWithCompletionHandler:^(NSData *d, NSError *e) {
        if (d.length) [self saveData:d name:[title stringByAppendingPathExtension:@"webarchive"]]; else [self showToast:@"Couldn't save the page"];
    }];
}

- (void)sharePage:(id)s {
    NSURL *u = [NSURL URLWithString:self.current.url ?: @""]; if (!u) return;
    NSSharingServicePicker *pk = [[NSSharingServicePicker alloc] initWithItems:@[u]];
    NSView *anchor = self.toolbar.menuBtn ?: self.toolbar;
    [pk showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMinY];
}
- (void)emailLink:(id)s {
    NSURL *u = [NSURL URLWithString:self.current.url ?: @""]; if (!u) return;
    NSSharingService *m = [NSSharingService sharingServiceNamed:NSSharingServiceNameComposeEmail];
    m.subject = self.current.title ?: u.host;
    if ([m canPerformWithItems:@[u]]) [m performWithItems:@[u]]; else [self showToast:@"No mail app is set up"];
}

- (void)openFile:(id)s {
    NSOpenPanel *o = [NSOpenPanel openPanel];
    o.allowedContentTypes = @[UTTypeHTML, UTTypePDF, UTTypeImage, UTTypePlainText, UTTypeSVG, [UTType typeWithFilenameExtension:@"webarchive"] ?: UTTypeData, UTTypeXML, UTTypeMovie, UTTypeAudio];
    o.allowsMultipleSelection = YES;
    [o beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        BOOL first = YES;
        for (NSURL *u in o.URLs) { [self newTab:u select:first]; first = NO; }
    }];
}

- (void)findSelection:(id)s {
    VPage *p = self.current.web; if (!p) return;
    [p.web evaluateJavaScript:@"String(getSelection()||'').trim().slice(0,200)" completionHandler:^(id r, NSError *e) {
        NSString *sel = [r isKindOfClass:NSString.class] ? r : @"";
        if (!sel.length) { NSBeep(); return; }
        [self showFind:nil];
        self.findBar.field.stringValue = sel;
        [self find:NO restart:YES];
    }];
}

static id Inspector(VPage *p) { @try { return [p.web valueForKey:@"_inspector"]; } @catch (NSException *e) { return nil; } }
- (void)showInspector:(id)s {
    id i = Inspector(self.current.web);
    if (i && [i respondsToSelector:@selector(show)]) [i performSelector:@selector(show)]; else [self showToast:@"Web Inspector isn't available"];
}
- (void)showConsole:(id)s {
    id i = Inspector(self.current.web);
    if (i && [i respondsToSelector:NSSelectorFromString(@"showConsole")]) ((void (*)(id, SEL))objc_msgSend)(i, NSSelectorFromString(@"showConsole")); else [self showInspector:s];
}

- (void)closeOtherTabs:(id)s {
    VTab *keep = self.current; if (!keep) return;
    NSUInteger n = 0;
    for (VTab *t in self.tabs.copy) if (t != keep && !t.pinned) { [self closeTab:t]; n++; }
    [self selectTab:keep];
    if (n) [self showToast:[NSString stringWithFormat:@"Closed %lu tab%@ · ⇧⌘T reopens", (unsigned long)n, n == 1 ? @"" : @"s"]];
}
- (void)moveTabLeft:(id)s { VTab *t = self.current; NSUInteger i = [self.tabs indexOfObject:t]; if (t && i != NSNotFound && i > 0) [self moveTab:t to:(NSInteger)i - 1]; }
- (void)moveTabRight:(id)s { VTab *t = self.current; NSUInteger i = [self.tabs indexOfObject:t]; if (t && i != NSNotFound && i + 1 < self.tabs.count) [self moveTab:t to:(NSInteger)i + 1]; }

@end

#pragma mark - Now playing: a small player at the foot of the sidebar (YouTube Music, YouTube, any site with media)

static NSString *MediaQueryJS(void) {
    return @"(()=>{const ms=navigator.mediaSession,m=ms&&ms.metadata;const v=[...document.querySelectorAll('video,audio')].find(x=>x.currentSrc&&x.duration>0)||null;"
            "if(!m&&!v)return null;const art=m&&m.artwork&&m.artwork.length?m.artwork[m.artwork.length-1].src:'';"
            "return{title:(m&&m.title)||document.title||'',artist:(m&&m.artist)||'',art:art,playing:v?!v.paused:(ms&&ms.playbackState==='playing'),pos:v?v.currentTime:0,dur:v&&isFinite(v.duration)?v.duration:0}})()";
}
// Video thumbnails often come letterboxed (black bands above and below, or at the sides); cut those off so the
// artwork fills its square with the picture itself.
static NSImage *TrimLetterbox(NSImage *im) {
    NSBitmapImageRep *rep = nil;
    for (NSImageRep *r in im.representations) if ([r isKindOfClass:NSBitmapImageRep.class]) { rep = (NSBitmapImageRep *)r; break; }
    if (!rep) { CGImageRef cg = [im CGImageForProposedRect:NULL context:nil hints:nil]; if (cg) rep = [[NSBitmapImageRep alloc] initWithCGImage:cg]; }
    NSInteger w = rep.pixelsWide, h = rep.pixelsHigh; if (w < 16 || h < 16) return im;
    BOOL (^dark)(NSInteger, NSInteger, BOOL) = ^BOOL(NSInteger i, NSInteger n, BOOL row) {   // every sampled pixel of row/column i is near black
        for (NSInteger k = 0; k < n; k += MAX(1, n / 48)) {
            NSColor *c = [[rep colorAtX:row ? k : i y:row ? i : k] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (MAX(c.redComponent, MAX(c.greenComponent, c.blueComponent)) > 0.09) return NO;
        }
        return YES;
    };
    NSInteger top = 0, bot = 0, left = 0, right = 0;
    while (top < h / 3 && dark(top, w, YES)) top++;
    while (bot < h / 3 && dark(h - 1 - bot, w, YES)) bot++;
    while (left < w / 3 && dark(left, h, NO)) left++;
    while (right < w / 3 && dark(w - 1 - right, h, NO)) right++;
    if (top + bot < h * 0.04 && left + right < w * 0.04) return im;
    CGImageRef cg = [rep CGImage]; if (!cg) return im;
    CGImageRef cut = CGImageCreateWithImageInRect(cg, CGRectMake(left, top, w - left - right, h - top - bot)); if (!cut) return im;
    NSImage *out = [[NSImage alloc] initWithCGImage:cut size:NSMakeSize(w - left - right, h - top - bot)];
    CGImageRelease(cut);
    return out;
}
static NSString *MediaControlJS(void) {
    return @"const q=s=>document.querySelector(s),click=(...ss)=>{for(const s of ss){const b=q(s);if(b){b.click();return true}}return false};"
            "const ytm=location.hostname.includes('music.youtube');const v=[...document.querySelectorAll('video,audio')].find(x=>x.currentSrc)||null;"
            "if(a==='toggle'){if(ytm&&click('#play-pause-button'))return true;if(v){v.paused?v.play():v.pause();return true}return click('[aria-label=\"Play\" i]','[aria-label=\"Pause\" i]')}"
            "if(a==='next')return click('.next-button','.ytp-next-button','[aria-label=\"Next\" i]','[aria-label=\"Next track\" i]');"
            "if(a==='prev'){if(click('.previous-button','.ytp-prev-button','[aria-label=\"Previous\" i]','[aria-label=\"Previous track\" i]'))return true;if(v){v.currentTime=0;return true}}"
            "return false";
}

@interface VNowPlaying : NSView
@property (weak) VWindow *owner;
@property (copy) NSDictionary *info;
@property (strong) NSImage *art;
@property (copy) NSString *artURL;
@property (strong) VButton *prev, *play, *next;
@end

@implementation VNowPlaying
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) return nil;
    self.prev = [VButton symbol:@"backward.fill" size:11 tip:@"Previous" target:self action:@selector(control:)]; self.prev.tag = 1;
    self.play = [VButton symbol:@"play.fill" size:14 tip:@"Play / pause" target:self action:@selector(control:)]; self.play.tag = 2;
    self.next = [VButton symbol:@"forward.fill" size:11 tip:@"Next" target:self action:@selector(control:)]; self.next.tag = 3;
    for (NSView *b in @[self.prev, self.play, self.next]) [self addSubview:b];
    return self;
}
- (BOOL)compact { return NSWidth(self.bounds) < 100; }
- (void)resizeSubviewsWithOldSize:(NSSize)o {
    CGFloat W = NSWidth(self.bounds);
    for (NSView *b in @[self.prev, self.next]) b.hidden = self.compact;
    if (self.compact) { self.play.frame = NSMakeRect(round((W - 40) / 2), 6, 40, 40); return; }   // narrow: just the artwork, which plays and pauses
    self.next.frame = NSMakeRect(W - 14 - 26, 18, 26, 28);
    self.play.frame = NSMakeRect(W - 14 - 26 - 28, 18, 28, 28);
    self.prev.frame = NSMakeRect(W - 14 - 26 - 28 - 26, 18, 26, 28);
}
- (void)drawRect:(NSRect)dirty {
    [vBg setFill]; NSRectFill(NSIntersectionRect(dirty, self.bounds));
    if (self.compact) {
        NSRect artR = NSMakeRect(round((NSWidth(self.bounds) - 40) / 2), 6, 40, 40);
        NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:artR xRadius:8 yRadius:8];
        if (self.art) { [NSGraphicsContext saveGraphicsState]; [clip addClip]; DrawImageFill(self.art, artR); [[NSColor colorWithWhite:0 alpha:0.35] setFill]; NSRectFillUsingOperation(artR, NSCompositingOperationSourceOver); [NSGraphicsContext restoreGraphicsState]; }
        else RoundRect(artR, 8, vPill);
        return;   // the play/pause button sits on top of the artwork
    }
    NSRect card = NSInsetRect(self.bounds, 8, 4);
    RoundRect(card, 10, vPill);
    NSRect artR = NSMakeRect(NSMinX(card) + 8, NSMinY(card) + 8, 40, 40);
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:artR xRadius:6 yRadius:6];
    if (self.art) { [NSGraphicsContext saveGraphicsState]; [clip addClip]; DrawImageFill(self.art, artR); [NSGraphicsContext restoreGraphicsState]; }
    else { RoundRect(artR, 6, vActive); NSImage *n = Tinted(Symbol(@"music.note", 14, NSFontWeightMedium), vFaint); DrawImage(n, CenterIn(n.size, artR)); }
    CGFloat tx = NSMaxX(artR) + 10, tw = NSMinX(self.prev.frame) - tx - 4;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [(self.info[@"title"] ?: @"") drawInRect:NSMakeRect(tx, NSMinY(card) + 10, tw, 17) withAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightMedium), NSForegroundColorAttributeName: vText, NSParagraphStyleAttributeName: ps}];
    NSString *artist = [self.info[@"artist"] length] ? self.info[@"artist"] : HostOf([NSURL URLWithString:self.owner.mediaTab.url ?: @""]);
    [artist drawInRect:NSMakeRect(tx, NSMinY(card) + 28, tw, 16) withAttributes:@{NSFontAttributeName: UIFont(11.5, NSFontWeightRegular), NSForegroundColorAttributeName: vDim, NSParagraphStyleAttributeName: ps}];
    double dur = [self.info[@"dur"] doubleValue], pos = [self.info[@"pos"] doubleValue];
    if (dur > 0) {   // a hairline of progress along the foot of the card
        NSRect track = NSMakeRect(NSMinX(card) + 10, NSMaxY(card) - 4, NSWidth(card) - 20, 2);
        RoundRect(track, 1, vActive);
        RoundRect(NSMakeRect(NSMinX(track), NSMinY(track), NSWidth(track) * MIN(1, pos / dur), 2), 1, vDim);
    }
}
- (void)mouseDown:(NSEvent *)e {   // clicking the card takes you to the music
    VTab *t = self.owner.mediaTab; if (t) [self.owner selectTab:t];
}
- (void)control:(VButton *)b {
    VTab *t = self.owner.mediaTab; if (!t.web) return;
    NSString *a = b.tag == 1 ? @"prev" : b.tag == 2 ? @"toggle" : @"next";
    [t.web.web callAsyncJavaScript:MediaControlJS() arguments:@{@"a": a} inFrame:nil inContentWorld:[WKContentWorld worldWithName:@"flint"] completionHandler:^(id r, NSError *err) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self.owner updateNowPlaying]; });
    }];
}
@end

@implementation VWindow (Media)

// Leaving a tab whose video is playing floats it in picture in picture; coming back docks it again.
// Music sites are left alone (the sidebar player covers them), and so is a tab still visible in split view.
- (void)autoPiPLeaving:(VTab *)old entering:(VTab *)t {
    if (![Defaults() boolForKey:kAutoPiP]) return;
    if ([self.splitPair containsObject:old] && [self.splitPair containsObject:t]) return;
    NSString *host = old.web.web.URL.host ?: @"";
    if (old.web && old.audible && !old.muted && ![host hasPrefix:@"music."] && ![host containsString:@"spotify"] && ![host containsString:@"soundcloud"])
        [old.web.web callAsyncJavaScript:@"const v=[...document.querySelectorAll('video')].find(v=>!v.paused&&!v.muted&&v.readyState>2&&v.videoWidth>0&&v.getBoundingClientRect().width>=200);"
                                          "if(!v||document.pictureInPictureElement||v.disablePictureInPicture)return false;await v.requestPictureInPicture();window.__flintAutoPiP=true;return true;"
                                arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
    if (t.web)
        [t.web.web callAsyncJavaScript:@"if(window.__flintAutoPiP&&document.pictureInPictureElement){window.__flintAutoPiP=false;await document.exitPictureInPicture()}"
                             arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
}
// Polled about once a second while there is music to show; it stops when the tab goes away.
- (void)updateNowPlaying {
    VNowPlaying *np = (VNowPlaying *)self.nowPlaying;
    if (!np) {
        np = [[VNowPlaying alloc] initWithFrame:NSMakeRect(0, 0, 230, 64)]; np.owner = self; np.hidden = YES;
        self.nowPlaying = np; [self.window.contentView addSubview:np];
    }
    VTab *t = self.mediaTab;
    if (!t || !t.web || ![self.tabs containsObject:t] || t == self.current) {   // nothing playing, or you're looking at it already
        if (!np.hidden) { np.hidden = YES; [self layout]; }
        return;
    }
    [t.web.web evaluateJavaScript:MediaQueryJS() inFrame:nil inContentWorld:[WKContentWorld worldWithName:@"flint"] completionHandler:^(id r, NSError *e) {
        NSDictionary *info = [r isKindOfClass:NSDictionary.class] ? r : nil;
        BOOL show = info && [info[@"title"] length];
        if (np.hidden == show) { np.hidden = !show; [self layout]; }
        if (!show) return;
        np.info = info;
        np.toolTip = [info[@"artist"] length] ? [NSString stringWithFormat:@"%@ — %@", info[@"title"], info[@"artist"]] : info[@"title"];
        np.play.symbolName = [info[@"playing"] boolValue] ? @"pause.fill" : @"play.fill"; np.play.needsDisplay = YES;
        NSString *art = [info[@"art"] isKindOfClass:NSString.class] ? info[@"art"] : @"";
        if (art.length && ![art isEqualToString:np.artURL] && [art hasPrefix:@"http"]) {
            np.artURL = art; np.art = nil;
            [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:art] completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
                NSImage *im = d ? [[NSImage alloc] initWithData:d] : nil; if (im) im = TrimLetterbox(im);
                dispatch_async(dispatch_get_main_queue(), ^{ if ([np.artURL isEqualToString:art]) { np.art = im; np.needsDisplay = YES; } });
            }] resume];
        } else if (!art.length) { np.artURL = nil; np.art = nil; }
        np.needsDisplay = YES;
        // keep the card current while something is loaded
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateNowPlaying) object:nil];
        [self performSelector:@selector(updateNowPlaying) withObject:nil afterDelay:[info[@"playing"] boolValue] ? 1.0 : 3.0];
    }];
}
@end

#pragma mark - Split view

// Two tabs share the page area side by side. Clicking a side makes it the current tab (the address bar
// follows it); the divider drags from 20% to 80%, and double-clicking it evens them out.
@interface VSplitDivider : NSView
@property (weak) VWindow *owner;
@end
@implementation VSplitDivider
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor]; }
- (void)drawRect:(NSRect)dirty {
    [vBg setFill]; NSRectFill(self.bounds);
    RoundRect(NSMakeRect(NSMidX(self.bounds) - 1.5, NSMidY(self.bounds) - 18, 3, 36), 1.5, [vText colorWithAlphaComponent:0.22]);
}
- (void)mouseDown:(NSEvent *)e {
    if (e.clickCount == 2) { self.owner.splitRatio = 0.5; [self.owner placePages]; }
}
- (void)mouseDragged:(NSEvent *)e {
    NSView *c = self.superview;
    CGFloat x = [c convertPoint:e.locationInWindow fromView:nil].x;
    self.owner.splitRatio = MAX(0.2, MIN(0.8, x / MAX(1, NSWidth(c.bounds))));
    [self.owner placePages];
}
@end

// "Load the open tab when you click it": at launch the tab you were on shows this card until you click.
@interface VResumeCard : NSView
@property (weak) VTab *tab;
@end
@implementation VResumeCard
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)drawRect:(NSRect)dirty {
    [vContentBg setFill]; NSRectFill(dirty);
    VTab *t = self.tab; if (!t) return;
    CGFloat W = NSWidth(self.bounds), cy = round(NSHeight(self.bounds) * 0.38);
    NSImage *ic = t.favicon ?: Tinted(Symbol(@"globe", 22, NSFontWeightRegular), vDim);
    DrawImage(ic, NSMakeRect(round(W / 2 - 16), cy - 52, 32, 32));
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [(t.title.length ? t.title : t.url ?: @"") drawInRect:NSMakeRect(40, cy, W - 80, 24) withAttributes:@{NSFontAttributeName: TitleFont(17, YES), NSForegroundColorAttributeName: vText, NSParagraphStyleAttributeName: ps}];
    [@"Click to load this page" drawInRect:NSMakeRect(40, cy + 30, W - 80, 18) withAttributes:@{NSFontAttributeName: UIFont(12.5, NSFontWeightRegular), NSForegroundColorAttributeName: vFaint, NSParagraphStyleAttributeName: ps}];
}
- (void)mouseDown:(NSEvent *)e { VTab *t = self.tab; t.deferred = NO; [t.owner placePages]; [t.owner refreshChrome]; }
@end

@implementation VWindow (Split)

- (NSView *)resumeCardFor:(VTab *)t {
    static char key;
    VResumeCard *c = objc_getAssociatedObject(self, &key);
    if (!c) { c = [[VResumeCard alloc] initWithFrame:NSZeroRect]; objc_setAssociatedObject(self, &key, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    c.tab = t; c.needsDisplay = YES;
    return c;
}

- (NSView *)paneFor:(VTab *)t {
    if (t.isHome) return self.home;
    if (!t.web && t.deferred) return [self resumeCardFor:t];
    if (!t.web) { VPage *p = [self makePage:t]; id st = t.savedState; t.savedState = nil; [p restoreState:st url:t.url]; }
    return t.web;
}

// Puts the current tab's page (and, in split view, its partner's) into the page area; everything else leaves it.
- (void)placePages {
    if (!self.content) return;
    NSArray<VTab *> *pair = self.splitPair;
    if (pair && (![self.tabs containsObject:pair[0]] || ![self.tabs containsObject:pair[1]] || (pair[0].isHome && pair[1].isHome))) { [self endSplit]; pair = nil; }
    VTab *cur = self.current;
    BOOL split = pair && [pair containsObject:cur];
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    for (VTab *t in (split ? pair : cur ? @[cur] : @[])) { NSView *v = [self paneFor:t]; if (v) [views addObject:v]; }
    if (split && views.count < 2) split = NO;
    for (NSView *v in self.content.subviews.copy)
        if (([v isKindOfClass:VPage.class] || v == self.home || [v isKindOfClass:VResumeCard.class]) && ![views containsObject:v]) [v removeFromSuperview];
    NSRect b = self.content.bounds;
    if (!split) {
        [self.splitDivider removeFromSuperview]; [self.splitMark removeFromSuperview];
        if (views.count) {
            NSView *v = views[0]; v.frame = b; v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            if (v.superview != self.content) [self.content addSubview:v positioned:NSWindowBelow relativeTo:nil];
        }
        return;
    }
    CGFloat gap = 6, r = self.splitRatio > 0.05 ? self.splitRatio : 0.5;
    CGFloat lw = round((NSWidth(b) - gap) * r);
    NSRect frames[2] = { NSMakeRect(0, 0, lw, NSHeight(b)), NSMakeRect(lw + gap, 0, NSWidth(b) - lw - gap, NSHeight(b)) };
    for (NSUInteger i = 0; i < 2; i++) {
        NSView *v = views[i]; v.frame = frames[i]; v.autoresizingMask = NSViewHeightSizable;
        if (v.superview != self.content) [self.content addSubview:v positioned:NSWindowBelow relativeTo:nil];
    }
    if (!self.splitDivider) { VSplitDivider *d = [[VSplitDivider alloc] initWithFrame:NSZeroRect]; d.owner = self; self.splitDivider = d; }
    self.splitDivider.frame = NSMakeRect(lw, 0, gap, NSHeight(b));
    if (self.splitDivider.superview != self.content) [self.content addSubview:self.splitDivider positioned:NSWindowAbove relativeTo:views.lastObject];
    self.splitDivider.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self.splitDivider];
    // a short bar at the top of the side the address bar is talking about
    if (!self.splitMark) {
        NSView *m = [[NSView alloc] initWithFrame:NSZeroRect]; m.wantsLayer = YES; m.layer.cornerRadius = 1.5;
        self.splitMark = m;
    }
    self.splitMark.layer.backgroundColor = [vText colorWithAlphaComponent:0.4].CGColor;
    NSRect act = frames[pair[0] == cur ? 0 : 1];
    CGFloat my = self.content.isFlipped ? 4 : NSHeight(b) - 7;
    self.splitMark.frame = NSMakeRect(round(NSMidX(act) - 18), my, 36, 3);
    if (self.splitMark.superview != self.content) [self.content addSubview:self.splitMark positioned:NSWindowAbove relativeTo:self.splitDivider];
}

- (void)endSplit {
    self.splitPair = nil;
    [self.splitDivider removeFromSuperview]; [self.splitMark removeFromSuperview];
    if (self.splitMonitor) { [NSEvent removeMonitor:self.splitMonitor]; self.splitMonitor = nil; }
}

- (void)splitWith:(VTab *)t {
    VTab *cur = self.current;
    if (!cur || !t || t == cur || ![self.tabs containsObject:t]) return;
    if (cur.isHome && t.isHome) { [self showToast:@"Open a page in one side first"]; return; }
    // the partner moves next to the current tab so the pair reads as one in the sidebar
    if (t.pinned == cur.pinned) {
        [self.tabs removeObject:t];
        [self.tabs insertObject:t atIndex:[self.tabs indexOfObject:cur] + 1];
    }
    self.splitPair = @[cur, t];
    if (self.splitRatio < 0.05) self.splitRatio = 0.5;
    if (!self.splitMonitor) {
        __weak VWindow *ws = self;
        self.splitMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown handler:^NSEvent *(NSEvent *e) {
            VWindow *s = ws;
            if (!s || e.window != s.window || ![s.splitPair containsObject:s.current]) return e;
            NSPoint p = [s.content convertPoint:e.locationInWindow fromView:nil];
            if (!NSPointInRect(p, s.content.bounds)) return e;
            for (VTab *x in s.splitPair) {
                NSView *v = x.isHome ? s.home : x.web;
                if (x != s.current && v.superview == s.content && NSPointInRect(p, v.frame)) { [s selectTab:x]; break; }
            }
            return e;
        }];
    }
    [self placePages];
    [self refreshChrome]; [self.sidebar reload]; [self scheduleSave];
}

- (void)toggleSplit:(id)s {
    VTab *cur = self.current; if (!cur) return;
    if ([self.splitPair containsObject:cur]) { [self endSplit]; [self placePages]; [self.sidebar reload]; return; }
    // the partner: the tab you were on last, or a fresh one to type into
    VTab *best = nil;
    for (VTab *t in self.tabs) if (t != cur && !(t.isHome && cur.isHome) && (!best || t.hiddenAt > best.hiddenAt)) best = t;
    if (!best) {
        if (cur.isHome) { [self showToast:@"Open a page first, then split"]; return; }
        NSSet *before = [NSSet setWithArray:self.tabs];
        [self newTab:nil select:NO];
        for (VTab *t in self.tabs) if (![before containsObject:t]) best = t;
        if (!best) return;
        [self splitWith:best];
        [self selectTab:best];
        return;
    }
    [self splitWith:best];
}

- (void)menuSplit:(NSMenuItem *)m {
    VTab *t = m.representedObject;
    if ([self.splitPair containsObject:t]) { [self endSplit]; [self placePages]; [self.sidebar reload]; }
    else if (t == self.current) [self toggleSplit:nil];
    else [self splitWith:t];
}

- (void)swapSplit:(id)s {
    NSArray *p = self.splitPair; if (p.count != 2) return;
    self.splitPair = @[p[1], p[0]];
    self.splitRatio = 1 - (self.splitRatio > 0.05 ? self.splitRatio : 0.5);
    [self placePages];
}

// "Open Link in Split View": the link opens beside this page (replacing the other side if already split).
- (void)splitLink:(NSMenuItem *)m {
    NSURL *u = [NSURL URLWithString:m.representedObject]; if (!u) return;
    VTab *cur = self.current;
    if ([self.splitPair containsObject:cur]) [self endSplit];
    NSSet *before = [NSSet setWithArray:self.tabs];
    [self newTab:u select:NO];
    for (VTab *t in self.tabs.copy) if (![before containsObject:t]) { [self splitWith:t]; break; }
}
@end

#pragma mark - The CPU rule: Flint averages at most one core over any 10 seconds

// One rule, always on: Flint plus every process it starts (page and extension engines, the network process)
// average at most one processor core over any 10 seconds. Short bursts run at full speed (a page draws in a
// few seconds), because fans answer heat built up over time, not a moment of work. Measured every 100 ms;
// while the 10-second average is under the cap nothing is touched; over it, Flint's helper processes are paced the way the `cpulimit` tool does it: in each 100 ms they run for
// a share of the time and pause for the rest, and that share is steered by what they actually used (a page
// runs on several cores at once, so a fixed split can't hold a cap). The graphics process and any page that
// is playing sound are paced last, so video and music stay smooth. Everything is resumed if Flint quits or
// crashes.

static pid_t gGovPids[256];            // processes Flint may have paused (read by the crash handler)
static volatile sig_atomic_t gGovCount;
static void GovResumeAll(void) { for (int i = 0; i < gGovCount; i++) if (gGovPids[i] > 0) kill(gGovPids[i], SIGCONT); }
static void GovCrash(int sig) { GovResumeAll(); signal(sig, SIG_DFL); raise(sig); }

static pid_t WebPid(WKWebView *v) {
    SEL s = NSSelectorFromString(@"_webProcessIdentifier");
    return v && [v respondsToSelector:s] ? ((pid_t (*)(id, SEL))objc_msgSend)(v, s) : 0;
}

// Every process macOS counts as Flint's (WebKit's engine, network and graphics processes are launched on
// Flint's behalf, so the system records Flint as "responsible" for them, which is how Activity Monitor groups them).
static NSArray<NSNumber *> *FlintHelperPids(void) {
    static pid_t (*responsible)(pid_t); static BOOL tried;
    if (!tried) { tried = YES; responsible = (pid_t (*)(pid_t))dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"); }
    if (!responsible) return @[];
    pid_t me = getpid();
    int n = proc_listallpids(NULL, 0); if (n <= 0) return @[];
    pid_t *all = calloc((size_t)n + 64, sizeof(pid_t));
    n = proc_listallpids(all, (int)(((size_t)n + 64) * sizeof(pid_t)));
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < n; i++) if (all[i] > 0 && all[i] != me && responsible(all[i]) == me) [out addObject:@(all[i])];
    free(all);
    return out;
}
static NSString *ProcName(pid_t p) { char b[PROC_PIDPATHINFO_MAXSIZE]; return proc_name(p, b, sizeof b) > 0 ? @(b) : @""; }
static double SelfCPUSeconds(void) {
    struct rusage r; getrusage(RUSAGE_SELF, &r);
    return r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6 + r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6;
}

@interface VGovernor : NSObject
+ (void)start;
+ (void)stop;
@end

@implementation VGovernor
static volatile BOOL gGovRunning;

// What may be paced: page and extension engines only. Never the graphics or network process (they carry video
// and audio), never a tab playing sound, and never the tab you clicked or typed in during the last 8 seconds
// (that's you pressing play: its first seconds of decoding and buffering must run free or the audio stutters).
+ (NSDictionary *)snapshot {
    NSMutableSet *spare = [NSMutableSet set];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (VTab *t in AllTabs(YES)) if (t.audible || now - t.lastInput < 8) { pid_t p = WebPid(t.web.web); if (p > 0) [spare addObject:@(p)]; }
    NSMutableArray *first = [NSMutableArray array];
    for (NSNumber *p in FlintHelperPids()) {
        NSString *name = ProcName(p.intValue);
        if (![name hasPrefix:@"com.apple.WebKit.WebContent"]) continue;
        if (![spare containsObject:p]) [first addObject:p];
    }
    NSMutableArray *measured = [NSMutableArray array];
    for (NSNumber *p in FlintHelperPids()) if ([ProcName(p.intValue) hasPrefix:@"com.apple.WebKit"] && ![first containsObject:p]) [measured addObject:p];
    return @{@"first": first, @"last": measured};
}

+ (void)start {
    if (gGovRunning) return;
    gGovRunning = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ int sigs[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP, SIGTERM}; for (int i = 0; i < 7; i++) signal(sigs[i], GovCrash); atexit(GovResumeAll); });
    [NSThread detachNewThreadWithBlock:^{
        [NSThread currentThread].qualityOfService = NSQualityOfServiceUtility;
        const double period = 0.1, cap = 1.0;   // the rule: one core, averaged over 10 s, Flint and everything it runs
        double frac = 1.0, lastSelf = SelfCPUSeconds();
        double ring[100] = {0}, ringSum = 0; int ri = 0;   // the last 10 s of use, one slot per period
        NSMutableDictionary<NSNumber *, NSNumber *> *last = [NSMutableDictionary dictionary];
        NSArray *first = @[], *late = @[]; NSTimeInterval lastSnap = 0, lastT = NSDate.date.timeIntervalSince1970, lastLog = 0;
        while (gGovRunning) {
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            if (now - lastSnap > 0.5) {
                __block NSDictionary *snap;
                dispatch_sync(dispatch_get_main_queue(), ^{ snap = [VGovernor snapshot]; });
                first = snap[@"first"]; late = snap[@"last"]; lastSnap = now;
                int n = 0; for (NSNumber *p in [first arrayByAddingObjectsFromArray:late]) if (n < 256) gGovPids[n++] = p.intValue;
                gGovCount = n;
                NSSet *live = [NSSet setWithArray:[first arrayByAddingObjectsFromArray:late]];
                for (NSNumber *p in last.allKeys) if (![live containsObject:p]) [last removeObjectForKey:p];
            }
            // total use over the last period, Flint itself included
            double dt = MAX(0.02, now - lastT); lastT = now;
            double me = SelfCPUSeconds(), total = (me - lastSelf) / dt; lastSelf = me;
            for (NSNumber *p in [first arrayByAddingObjectsFromArray:late]) {
                double c = ProcessCPUSeconds(p.intValue);
                if (last[p]) total += MAX(0, c - last[p].doubleValue) / dt;
                last[p] = @(c);
            }
            ringSum += total - ring[ri]; ring[ri] = total; ri = (ri + 1) % 100;
            double avg = ringSum / 100;
            // only when the 10-second average is over the cap: steer the helpers' share of time so use comes back
            // down to it; once the average is comfortably under, let them run free again
            // (never below a quarter of the time: when the load comes from what can't be paced, graphics, sound or
            //  the tab you're using, squeezing the rest harder only starves them without cooling anything)
            if (avg > cap && total > cap) frac = MAX(0.25, frac * pow(cap / total, 0.8));
            else if (avg < cap * 0.9) frac = MIN(1.0, frac * 1.25);
            if (now - lastLog > 10 && frac < 1) { lastLog = now; DLog(@"cpu rule: now %.2f cores, 10 s average %.2f, helpers running %.0f%% of the time", total, avg, frac * 100); }
            if (frac >= 1) { usleep((useconds_t)(period * 1e6)); continue; }   // under the cap: nothing touched
            // plain pages and extensions take the pause; graphics and sound only when that isn't enough
            NSArray *pause = first;
            usleep((useconds_t)(period * frac * 1e6));
            for (NSNumber *p in pause) kill(p.intValue, SIGSTOP);
            usleep((useconds_t)(period * (1 - frac) * 1e6));
            for (NSNumber *p in pause) kill(p.intValue, SIGCONT);
        }
        GovResumeAll();
    }];
}
+ (void)stop { gGovRunning = NO; GovResumeAll(); }
@end
#pragma mark - Test harness: commands from control.txt, screenshots into shots/

// Development aid. Write lines to control.txt beside Flint.app; each runs once, in order:
//   open URL | tab URL | select N | close | back | forward | reload | scroll DY | top | find TEXT
//   zoom Z | block on|off | wait SECONDS | shot NAME | source NAME | js EXPR | status | size W H
//   window (a fresh window runs the rest) | win N | closewindow | bookmarksbar on|off | sidebar WIDTH
// Results and status lines are appended to control.out.

@interface VWindow (Control)
- (void)startControl;
@end

@implementation VWindow (Control)

static NSString *CtlDir(void) { return NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent; }

static void CtlOut(NSString *s) {
    if (!s) return;
    NSString *p = [CtlDir() stringByAppendingPathComponent:@"control.out"];
    NSString *line = [s stringByAppendingString:@"\n"];
    dispatch_async(DevQueue(), ^{   // off the main thread: a macOS folder-access prompt must never freeze the browser
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!h) { [line writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
        [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
    });
}

- (void)startControl {
    static NSDate *seen;
    NSString *p = [CtlDir() stringByAppendingPathComponent:@"control.txt"];
    static BOOL busy;
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        if (busy) return;
        busy = YES;
        dispatch_async(DevQueue(), ^{   // the file is read in the background; commands run on the main thread
            NSDate *m = [[NSFileManager.defaultManager attributesOfItemAtPath:p error:nil] fileModificationDate];
            NSString *text = nil; BOOL run = NO;
            if (m && ![m isEqualToDate:seen]) {
                BOOL first = seen == nil; seen = m;
                run = !(first && -[m timeIntervalSinceNow] > 5);   // stale file from an earlier run
                if (run) text = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                busy = NO;
                if (!run) return;
                NSMutableArray *lines = [NSMutableArray array];
                for (NSString *l in [text componentsSeparatedByString:@"\n"]) { NSString *x = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; if (x.length) [lines addObject:x]; }
                [self runControl:lines];
            });
        });
    }];
}

- (void)runControl:(NSMutableArray *)lines {
    while (lines.count) {
        NSString *l = lines.firstObject; [lines removeObjectAtIndex:0];
        NSRange sp = [l rangeOfString:@" "];
        NSString *cmd = sp.location == NSNotFound ? l : [l substringToIndex:sp.location];
        NSString *arg = sp.location == NSNotFound ? @"" : [l substringFromIndex:sp.location + 1];
        VPage *w = self.current.web;
        if ([cmd isEqualToString:@"wait"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(arg.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self runControl:lines]; });
            return;
        }
        else if ([cmd isEqualToString:@"open"]) [self go:arg];
        else if ([cmd isEqualToString:@"tab"]) [self newTab:URLFromInput(arg) select:YES];
        else if ([cmd isEqualToString:@"select"]) { NSInteger i = arg.integerValue; if (i >= 0 && i < (NSInteger)self.tabs.count) [self selectTab:self.tabs[i]]; }
        else if ([cmd isEqualToString:@"close"]) { if (self.current) [self closeTab:self.current]; }
        else if ([cmd isEqualToString:@"back"]) [w goBack];
        else if ([cmd isEqualToString:@"forward"]) [w goForward];
        else if ([cmd isEqualToString:@"reload"]) [w reload];
        else if ([cmd isEqualToString:@"scroll"]) [w runJS:[NSString stringWithFormat:@"window.scrollBy(0,%f)", arg.doubleValue]];
        else if ([cmd isEqualToString:@"top"]) [w runJS:@"window.scrollTo(0,0)"];
        else if ([cmd isEqualToString:@"act"] && [@[@"toggleSplit:", @"swapSplit:", @"toggleReader:", @"showFind:", @"closePeek:"] containsObject:arg]) {
            [NSApp sendAction:NSSelectorFromString(arg) to:self from:nil];
            CtlOut([NSString stringWithFormat:@"act %@ split=%lu", arg, (unsigned long)self.splitPair.count]);
        }
        else if ([cmd isEqualToString:@"window"]) {   // a fresh window; the rest of the commands run in it
            VWindow *nw = [[VWindow alloc] initPrivate:NO state:@{}]; [nw showWindow:nil]; [nw windowDidResize:nil];
            [nw.window makeKeyAndOrderFront:nil];
            CtlOut(@"window opened");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [nw runControl:lines]; });
            return;
        }
        else if ([cmd isEqualToString:@"closewindow"]) { if (gWindows.count > 1) { CtlOut(@"window closed"); [self.window performClose:nil]; CtlOut(@"done"); return; } }
        else if ([cmd isEqualToString:@"win"]) {   // the rest of the commands run in window N (oldest first)
            NSInteger i = arg.integerValue;
            if (i >= 0 && i < (NSInteger)gWindows.count) { VWindow *x = gWindows[i]; CtlOut([NSString stringWithFormat:@"win %ld of %lu", (long)i, (unsigned long)gWindows.count]); [x runControl:lines]; return; }
        }
        else if ([cmd isEqualToString:@"sidebar"]) { CGFloat wdt = arg.doubleValue; if (wdt >= 40 && wdt <= 420) { [Defaults() setDouble:wdt forKey:kSidebarW]; RelayoutAll(); } CtlOut([NSString stringWithFormat:@"sidebar %.0f", SidebarWidth()]); }
        else if ([cmd isEqualToString:@"bookmarksbar"]) { [Defaults() setBool:[arg isEqualToString:@"on"] forKey:kShowBookmarks]; RelayoutAll(); }
        else if ([cmd isEqualToString:@"extinstall"]) {   // a Chrome Web Store link or extension id (takes effect at the next launch)
            [FExtHost.shared installFromWebStore:arg done:^(NSString *name, NSString *err) { CtlOut([NSString stringWithFormat:@"extinstall %@ %@", name ?: @"-", err ?: @"ok"]); }];
        }
        else if ([cmd isEqualToString:@"rules"]) {
            for (NSString *k in gExtRuleLists) CtlOut([NSString stringWithFormat:@"rules %@: %lu lists", k, (unsigned long)gExtRuleLists[k].count]);
            CtlOut([NSString stringWithFormat:@"rules gUCC total lists attached: (blocker %lu)", (unsigned long)gRules.count]);
        }
        else if ([cmd isEqualToString:@"media"]) {
            for (VTab *t in self.tabs) CtlOut([NSString stringWithFormat:@"media tab=%@ key=%@ time=%.0f saved=%.0f resume=%.0f web=%d", t.url ?: @"-", t.mediaKey ?: @"-", t.mediaTime, t.savedMedia, t.resumeAt, t.web != nil]);
            for (NSDictionary *d in [Defaults() dictionaryForKey:kTabsState][@"tabs"]) CtlOut([NSString stringWithFormat:@"media saved url=%@ key=%@ time=%@", d[@"url"], d[@"mediaKey"] ?: @"-", d[@"mediaTime"] ?: @"-"]);
        }
        else if ([cmd isEqualToString:@"find"]) [w find:arg forward:YES next:NO];
        else if ([cmd isEqualToString:@"zoom"]) [w setZoomLevel:arg.doubleValue];
        else if ([cmd isEqualToString:@"block"]) { BOOL on = [arg isEqualToString:@"on"]; if (on != [Defaults() boolForKey:kBlock]) [self performSelector:@selector(toggleBlockingGlobal:) withObject:nil]; }
        else if ([cmd isEqualToString:@"size"]) { NSArray *a = [arg componentsSeparatedByString:@" "]; if (a.count == 2) { NSRect f = self.window.frame; f.size = NSMakeSize([a[0] doubleValue], [a[1] doubleValue]); [self.window setFrame:f display:YES]; } }
        else if ([cmd isEqualToString:@"procs"]) {   // engine process per tab / extension background, to match CPU samples
            SEL pidSel = NSSelectorFromString(@"_webProcessIdentifier");
            pid_t (^pidOf)(WKWebView *) = ^pid_t(WKWebView *v) { return v && [v respondsToSelector:pidSel] ? ((pid_t (*)(id, SEL))objc_msgSend)(v, pidSel) : 0; };
            NSMutableString *o = [NSMutableString stringWithFormat:@"procs flint=%d throttleHard=%d battery=%d\n", getpid(), ThrottleHard(), OnBattery()];
            for (VTab *t in AllTabs(YES)) if (t.web) [o appendFormat:@"  tab pid=%d %@\n", pidOf(t.web.web), HostOf([NSURL URLWithString:t.url ?: @""])];
            for (FExt *e in FExtHost.shared.extensions) if ([e isKindOfClass:FExt.class] && e.background) [o appendFormat:@"  ext pid=%d %@\n", pidOf(e.background), e.name];
            CtlOut(o);
        }
        else if ([cmd isEqualToString:@"status"]) {
            CtlOut([NSString stringWithFormat:@"status tabs=%lu cur=%lu url=%@ title=%@ loading=%d progress=%.2f blocked=%ld rules=%lu extensions=%d side=%.0f split=%lu",
                    (unsigned long)self.tabs.count, (unsigned long)[self.tabs indexOfObject:self.current], w.url, w.title, w.loading, w.progress, (long)w.blocked,
                    (unsigned long)gRuleCount, (int)FExtHost.shared.extensions.count, NSWidth(self.sideScroll.frame), (unsigned long)self.splitPair.count]);
            NSView *hd = [self valueForKey:@"sideHandle"]; NSRect hr = [self.window convertRectToScreen:[hd convertRect:hd.bounds toView:nil]];
            CtlOut([NSString stringWithFormat:@"handle screen x=%.0f..%.0f y=%.0f..%.0f (top-left origin, screen h=%.0f) superview=%@ hidden=%d", NSMinX(hr), NSMaxX(hr), NSScreen.mainScreen.frame.size.height - NSMaxY(hr), NSScreen.mainScreen.frame.size.height - NSMinY(hr), NSScreen.mainScreen.frame.size.height, NSStringFromClass(hd.superview.class), hd.hidden]);
        }
        else if ([cmd isEqualToString:@"js"]) [w runJS:arg];
        else if ([cmd isEqualToString:@"extcopy"] && arg.length && ![arg containsString:@"/"] && ![arg hasPrefix:@"."]) {   // dev: copy an installed extension out for inspection
            NSString *src = [ExtRoot() stringByAppendingPathComponent:arg], *dst = [[CtlDir() stringByAppendingPathComponent:@"ext-debug"] stringByAppendingPathComponent:arg];
            [NSFileManager.defaultManager createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
            NSError *err = nil; [NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:&err];
            CtlOut([NSString stringWithFormat:@"extcopy %@ %@", arg, err ? err.localizedDescription : @"ok"]);
        }
        else if ([cmd isEqualToString:@"extlist"]) CtlOut([@"extlist " stringByAppendingString:[[NSFileManager.defaultManager contentsOfDirectoryAtPath:ExtRoot() error:nil] componentsJoinedByString:@" "]]);
        else if ([cmd isEqualToString:@"popup"]) [FExtHost.shared openPopup:nil from:nil];
        else if ([cmd isEqualToString:@"isojs"]) {   // the first extension's content-script world, in this tab
            FExt *e = FExtHost.shared.extensions.firstObject;
            [w.web callAsyncJavaScript:[NSString stringWithFormat:@"const r = await (%@); return typeof r === 'object' ? JSON.stringify(r) : String(r);", arg] arguments:@{} inFrame:nil inContentWorld:e.world
                     completionHandler:^(id r, NSError *err) { CtlOut([NSString stringWithFormat:@"isojs %@", err ? (err.userInfo[@"WKJavaScriptExceptionMessage"] ?: err.localizedDescription) : r]); }];
        }
        else if ([cmd isEqualToString:@"popupjs"] || [cmd isEqualToString:@"bgjs"]) [FExtHost.shared evalIn:[cmd substringToIndex:cmd.length - 2] code:arg];
        else if ([cmd isEqualToString:@"source"]) {
            NSString *name = arg.length ? arg : @"source.html";
            [w source:^(NSString *d) {
                NSString *dir = [CtlDir() stringByAppendingPathComponent:@"shots"];
                [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                [d writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                CtlOut([NSString stringWithFormat:@"source %@ (%lu chars)", name, (unsigned long)d.length]);
            }];
        }
        else if ([cmd isEqualToString:@"shot"]) {
            // the whole window as the screen shows it, Chromium's layers included
            typedef CGImageRef (*Grab)(CGRect, uint32_t, uint32_t, uint32_t);
            Grab grab = (Grab)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
            NSBitmapImageRep *rep = nil;
            if (grab) { CGImageRef img = grab(CGRectNull, 8 /* including window */, (uint32_t)self.window.windowNumber, 1 /* ignore framing */); if (img) { rep = [[NSBitmapImageRep alloc] initWithCGImage:img]; CGImageRelease(img); } }
            if (!rep) {
                NSView *v = self.window.contentView.superview ?: self.window.contentView;
                rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
                [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
            }
            NSString *dir = [CtlDir() stringByAppendingPathComponent:@"shots"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *f = [dir stringByAppendingPathComponent:[(arg.length ? arg : @"shot") stringByAppendingPathExtension:@"png"]];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:f atomically:YES];
            CtlOut([NSString stringWithFormat:@"shot %@", f.lastPathComponent]);
        }
        else CtlOut([@"unknown " stringByAppendingString:l]);
    }
    CtlOut(@"done");
}

@end
#pragma mark - Theme

static void FlintApplyTheme(void) {
    InitPalette();
    NSApp.appearance = [Defaults() integerForKey:kTheme] == 0 ? nil : ThemeAppearance();
    for (VWindow *bw in gWindows) [bw applyTheme];
    for (VTab *t in AllTabs(YES)) if ([t.url hasPrefix:@"flint://"] && t.web) [t.web reload];   // built-in pages carry the theme's colours
    for (NSWindow *w in NSApp.windows) if (![w.windowController isKindOfClass:VWindow.class]) { w.appearance = ThemeAppearance(); w.backgroundColor = vBg; if (w.contentView) RedrawTree(w.contentView); }
}

#pragma mark - App

// A menu target that is always "the browser window you're using", whichever one that is.
@interface VWinProxy : NSObject
+ (instancetype)shared;
@end
@implementation VWinProxy
+ (instancetype)shared { static VWinProxy *p; static dispatch_once_t once; dispatch_once(&once, ^{ p = [VWinProxy new]; }); return p; }
- (id)forwardingTargetForSelector:(SEL)s { return gWin; }
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [gWin respondsToSelector:s]; }
@end

@implementation VApp

// Development builds wait in .staged/ next to Flint.app instead of restarting Flint mid-use. Flint shows
// an "Update" pill while one is waiting; clicking it asks the watcher to swap the app in and reopen it.
static NSString *StageDir(void) { return [NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".staged"]; }
static void RunBuildScript(NSString *stamp);
// Plugging in or unplugging changes how hard background tabs are throttled.
- (void)applyThrottleNow {
    BOOL hard = ThrottleHard();
    for (VTab *t in AllTabs(YES)) if (t.web) ApplyThrottle(t.web.web, hard);
}
- (void)checkPower {
    static int last = -1;
    int hard = ThrottleHard();
    if (hard != last) { last = hard; for (VTab *t in AllTabs(YES)) if (t.web) ApplyThrottle(t.web.web, hard); }
}
- (void)checkForStagedBuild {
    dispatch_async(DevQueue(), ^{
        NSString *dir = StageDir();
        BOOL ready = [NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"ready"]];
        NSString *notes = ready ? [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"notes"] encoding:NSUTF8StringEncoding error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ready == gUpdateReady && (notes == gUpdateNotes || [notes isEqualToString:gUpdateNotes])) return;
            gUpdateReady = ready; gUpdateNotes = Trim(notes ?: @"");
            if (!ready) gUpdating = NO;
            for (VWindow *w in gWindows) [w.toolbar layoutBar];
        });
    });
}
- (void)installUpdate:(id)s {
    if (gUpdating) return;
    gUpdating = YES;
    for (VWindow *w in gWindows) [w.toolbar layoutBar];
    for (VWindow *w in gWindows) if (!w.isPrivate) { [w saveSession]; break; }
    [Defaults() synchronize];
    dispatch_async(DevQueue(), ^{
        [@"install" writeToFile:[StageDir() stringByAppendingPathComponent:@"install"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        RunBuildScript(nil);   // with an install request waiting, the script quits Flint, swaps the app in and reopens it
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!gUpdating) return;
        gUpdating = NO;
        for (VWindow *w in gWindows) [w.toolbar layoutBar];
        [gWin showToast:@"The update didn't go through — see build.log in the Flint folder"];
    });
}

// Flint builds itself: while it's open it watches its own source next to the app, compiles changes in the
// background into .staged/, and the Update pill appears. No Terminal window needed.
static NSString *BuildStamp(void) {
    NSString *d = StageDir().stringByDeletingLastPathComponent; NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *files = [@[@"Flint.m", @"ext-shim.js", @"flint", @".rebuild", @"Flint.icns"] mutableCopy];
    for (NSString *f in [[fm contentsOfDirectoryAtPath:[d stringByAppendingPathComponent:@"pages"] error:nil] sortedArrayUsingSelector:@selector(compare:)]) [files addObject:[@"pages" stringByAppendingPathComponent:f]];
    NSMutableString *s = [NSMutableString string];
    for (NSString *f in files) {
        NSDictionary *a = [fm attributesOfItemAtPath:[d stringByAppendingPathComponent:f] error:nil];
        if (a) [s appendFormat:@"%@:%.3f:%llu;", f, a.fileModificationDate.timeIntervalSince1970, a.fileSize];
    }
    return s;
}
static BOOL gBuilding;
static NSString *gSeenStamp; static NSTimeInterval gSeenAt;
// Runs the build script (a fresh copy, so editing it mid-build is safe). Call on DevQueue.
static void RunBuildScript(NSString *stamp) {
    NSString *d = StageDir().stringByDeletingLastPathComponent, *script = [d stringByAppendingPathComponent:@"flint"], *copy = [d stringByAppendingPathComponent:@".flint-run"];
    if (![NSFileManager.defaultManager fileExistsAtPath:script]) return;
    [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
    [NSFileManager.defaultManager copyItemAtPath:script toPath:copy error:nil];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    t.arguments = @[copy];
    t.currentDirectoryURL = [NSURL fileURLWithPath:d];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice; t.standardError = NSFileHandle.fileHandleWithNullDevice;
    gBuilding = YES;
    t.terminationHandler = ^(NSTask *task) {
        int code = task.terminationStatus;
        dispatch_async(DevQueue(), ^{
            gBuilding = NO;
            if (stamp) [stamp writeToFile:[d stringByAppendingPathComponent:@".built-stamp"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *st = [NSString stringWithContentsOfFile:[d stringByAppendingPathComponent:@"watch.status"] encoding:NSUTF8StringEncoding error:nil];
            NSInteger n = [[st componentsSeparatedByString:@" "].firstObject integerValue] + 1;
            [[NSString stringWithFormat:@"%ld %@ %.0f\n", (long)n, code == 0 ? @"ok" : @"failed", NSDate.date.timeIntervalSince1970]
                writeToFile:[d stringByAppendingPathComponent:@"watch.status"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [gApp checkForStagedBuild]; });
        });
    };
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) gBuilding = NO;
}
- (void)watchOwnSource {
    dispatch_async(DevQueue(), ^{
        NSString *d = StageDir().stringByDeletingLastPathComponent;
        if (gBuilding || ![NSFileManager.defaultManager fileExistsAtPath:[d stringByAppendingPathComponent:@"flint"]]) return;
        NSString *st = BuildStamp();
        NSString *built = [NSString stringWithContentsOfFile:[d stringByAppendingPathComponent:@".built-stamp"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
        if ([st isEqualToString:built]) { gSeenStamp = nil; return; }
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (![st isEqualToString:gSeenStamp]) { gSeenStamp = st; gSeenAt = now; return; }   // changing: wait until it settles
        if (now - gSeenAt < 3) return;
        gSeenStamp = nil;
        RunBuildScript(st);
    });
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [Defaults() registerDefaults:@{kDLAccel: @YES, kCodec: @(MacIsAppleSilicon() ? 0 : 2), kCodec30: @NO, kBgThrottle: @1, kSingleProcess: @NO, kRestorePaused: @YES, kResumeMedia: @YES, kLazyRestore: @NO, kBlock: @YES, kStrip: @YES, kCookieReject: @YES, kAutoPiP: @YES, kSleepMins: @10, kShowBookmarks: @YES, kSearch: @0, kStartup: @0, kScripts: @YES, kAskDownload: @NO,
                                   kTheme: @1, kAccent: @0, kDensity: @1, kHTTPSOnly: @NO, kGPC: @YES, kHomeTopSites: @YES, kConfirmQuit: @NO, kSuggestNet: @YES}];
    InitPalette();
    if ([Defaults() integerForKey:kTheme] != 0) NSApp.appearance = ThemeAppearance();
    // the Dock keeps an old icon for ad-hoc builds; hand it the current one directly
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"Flint" ofType:@"icns"]];
    if (icon) NSApp.applicationIconImage = icon;
    // "Follow macOS": recolour when the system switches between light and dark
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"AppleInterfaceThemeChangedNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if ([Defaults() integerForKey:kTheme] == 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ FlintApplyTheme(); });
    }];
    FlintSetBlocking([Defaults() boolForKey:kBlock]);
    FlintReloadBlocklists();
    self.win = [VWindow new];
    [self buildMenu];
    [self.win showWindow:nil];
    [self.win windowDidResize:nil];
    // other windows from last time come back behind the main one
    NSArray *extra = [Defaults() dictionaryForKey:kTabsState][@"windows"];
    if ([Defaults() integerForKey:kStartup] == 0 && [extra isKindOfClass:NSArray.class])
        for (NSDictionary *d in extra) if ([d isKindOfClass:NSDictionary.class]) { VWindow *x = [[VWindow alloc] initPrivate:NO state:d]; [x.window orderWindow:NSWindowBelow relativeTo:self.win.window.windowNumber]; [x windowDidResize:nil]; }
    gWin = self.win; [self.win.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self checkForStagedBuild];
    __weak VApp *ws = self;
    [NSTimer scheduledTimerWithTimeInterval:4 repeats:YES block:^(NSTimer *t) { [ws checkForStagedBuild]; }];
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { [ws watchOwnSource]; }];
    [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) { [ws checkPower]; }];
    // pages that grow a video after loading (YouTube moving between videos): the PiP button follows
    [NSTimer scheduledTimerWithTimeInterval:2.5 repeats:YES block:^(NSTimer *t) { for (VWindow *w in gWindows) { if (w.window.isVisible) [w.current.web checkVideo]; for (VTab *x in w.tabs) { if (x.web && x.resumeAt > 0 && !x.resuming && !x.web.web.isLoading) [x.web resumeMedia]; if (x.web && (x == w.current || x.audible)) [x.web noteMediaTime]; } } }];
    [VBlocker.shared prepare:nil];
    [self.win startControl];
    [FExtHost.shared start];
    [VGovernor start];   // the CPU rule: Flint and its helpers stay under 95% of one core
    [self fillMissingIcons];
}

// Bookmarks and restored tabs that have never been visited in Flint still get their site icons.
- (void)fillMissingIcons {
    NSMutableOrderedSet<NSString *> *urls = [NSMutableOrderedSet orderedSet];
    for (VTab *t in gWin.tabs) if (!t.favicon && [t.url hasPrefix:@"http"]) [urls addObject:t.url];
    for (NSDictionary *b in VBookmarks.shared.allURLs) { NSString *u = b[@"url"]; if ([u hasPrefix:@"http"] && ![VFavicons.shared iconForURL:u]) [urls addObject:u]; }
    NSUInteger i = 0;
    for (NSString *u in urls) {
        NSURL *page = [NSURL URLWithString:u]; if (!page) continue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i++ * 150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [VFavicons.shared fetchFor:page href:nil done:^(NSImage *im) {
                for (VTab *t in gWin.tabs) if (!t.favicon && [HostOf([NSURL URLWithString:t.url ?: @""]) isEqualToString:HostOf(page)]) t.favicon = im;
                [gWin refreshChrome]; [gWin.bookmarksBar reload];
            }];
        });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    NSUInteger open = 0; for (VTab *t in AllTabs(YES)) if (!t.isHome) open++;
    if ([Defaults() boolForKey:kConfirmQuit] && open > 1 && !self.quitConfirmed) {
        NSAlert *a = [NSAlert new]; a.messageText = [NSString stringWithFormat:@"Quit Flint with %lu tabs open?", (unsigned long)open];
        a.informativeText = @"They'll be restored next time if Flint is set to continue where you left off.";
        [a addButtonWithTitle:@"Quit"]; [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] != NSAlertFirstButtonReturn) return NSTerminateCancel;
    }
    [self.win saveSession]; gQuitting = YES;   // saved before anything starts closing
    if (![Defaults() boolForKey:kClearOnQuit]) return NSTerminateNow;
    [WKWebsiteDataStore.defaultDataStore removeDataOfTypes:WKWebsiteDataStore.allWebsiteDataTypes modifiedSince:NSDate.distantPast completionHandler:^{
        [NSApp replyToApplicationShouldTerminate:YES];
    }];
    return NSTerminateLater;
}
- (void)applicationWillTerminate:(NSNotification *)n { [VGovernor stop]; if (!gQuitting) [self.win saveSession]; gQuitting = YES; [VHistory flushAll]; }

- (BOOL)application:(NSApplication *)a openFile:(NSString *)f { [gWin openURL:[NSURL fileURLWithPath:f] newTab:YES]; return YES; }
- (void)application:(NSApplication *)a openURLs:(NSArray<NSURL *> *)urls { for (NSURL *u in urls) [gWin openURL:u newTab:YES]; }

// Settings is a page, flint://settings, in the window you're using (a new window if none is open).
- (void)showSettings:(id)s {
    VWindow *w = gWin;
    if (!w.window.isVisible) { w = [VWindow new]; [w showWindow:nil]; }
    [w showSettingsSection:@"general"];
}
- (void)showSettingsSection:(NSNumber *)n {
    NSArray *ids = @[@"general", @"appearance", @"search", @"privacy", @"sites", @"blocking", @"performance", @"extensions", @"downloads", @"bookmarks", @"shortcuts", @"advanced", @"about"];
    NSInteger i = [n isKindOfClass:NSNumber.class] ? n.integerValue : 0;
    [gWin showSettingsSection:ids[(NSUInteger)MAX(0, MIN((NSInteger)ids.count - 1, i))]];
}
- (void)showExtensions:(id)s { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:ExtRoot()]]; }
- (void)openFirstExtension:(id)s { [FExtHost.shared openPopup:nil from:nil]; }

- (NSMenuItem *)item:(NSString *)t action:(SEL)a key:(NSString *)k mods:(NSEventModifierFlags)m in:(NSMenu *)menu target:(id)target {
    NSMenuItem *it = [menu addItemWithTitle:t action:a keyEquivalent:k ?: @""];
    if (k.length) it.keyEquivalentModifierMask = m;
    it.target = target;
    return it;
}

- (void)buildMenu {
    NSEventModifierFlags C = NSEventModifierFlagCommand, S = NSEventModifierFlagShift, O = NSEventModifierFlagOption, K = NSEventModifierFlagControl;
    NSMenu *bar = [NSMenu new];
    id W = nil;   // window actions resolve at call time through gWin
    (void)W;

    NSMenu *app = [[NSMenu alloc] initWithTitle:@"Flint"];
    [self item:@"About Flint" action:@selector(orderFrontStandardAboutPanel:) key:nil mods:0 in:app target:NSApp];
    [app addItem:NSMenuItem.separatorItem];
    [self item:@"Settings…" action:@selector(showSettings:) key:@"," mods:C in:app target:self];
    [self item:@"Open Proton Pass" action:@selector(openFirstExtension:) key:@"p" mods:C | O in:app target:self];
    [self item:@"Extensions Folder…" action:@selector(showExtensions:) key:nil mods:0 in:app target:self];
    [app addItem:NSMenuItem.separatorItem];
    [self item:@"Hide Flint" action:@selector(hide:) key:@"h" mods:C in:app target:NSApp];
    [self item:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" mods:C | O in:app target:NSApp];
    [self item:@"Show All" action:@selector(unhideAllApplications:) key:nil mods:0 in:app target:NSApp];
    [app addItem:NSMenuItem.separatorItem];
    [self item:@"Quit Flint" action:@selector(terminate:) key:@"q" mods:C in:app target:NSApp];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = app;

    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    [self item:@"New Tab" action:@selector(newTabAction:) key:@"t" mods:C in:file target:nil];
    [self item:@"New Window" action:@selector(newWindow:) key:@"n" mods:C in:file target:self];
    [self item:@"New Private Window" action:@selector(newPrivateWindow:) key:@"n" mods:C | S in:file target:self];
    NSMenuItem *profs = [file addItemWithTitle:@"Profiles" action:nil keyEquivalent:@""];
    NSMenu *pm = [[NSMenu alloc] initWithTitle:@"Profiles"]; pm.delegate = self; profs.submenu = pm;   // filled in each time it opens
    [self item:@"Reopen Closed Tab" action:@selector(reopenClosed:) key:@"t" mods:C | S in:file target:nil];
    [self item:@"Open Location…" action:@selector(openLocation:) key:@"l" mods:C in:file target:nil];
    [self item:@"Open File…" action:@selector(openFile:) key:@"o" mods:C in:file target:nil];
    [file addItem:NSMenuItem.separatorItem];
    [self item:@"Save Page…" action:@selector(savePage:) key:@"s" mods:C | S in:file target:nil];
    [self item:@"Save as Web Archive…" action:@selector(saveWebArchive:) key:nil mods:0 in:file target:nil];
    [self item:@"Export as PDF…" action:@selector(exportPDF:) key:nil mods:0 in:file target:nil];
    [file addItem:NSMenuItem.separatorItem];
    [self item:@"Share…" action:@selector(sharePage:) key:nil mods:0 in:file target:nil];
    [self item:@"Email Link to This Page" action:@selector(emailLink:) key:@"i" mods:C in:file target:nil];
    [file addItem:NSMenuItem.separatorItem];
    [self item:@"Print…" action:@selector(printPage:) key:@"p" mods:C in:file target:nil];
    [file addItem:NSMenuItem.separatorItem];
    [self item:@"Close Tab" action:@selector(closeTabAction:) key:@"w" mods:C in:file target:nil];
    [self item:@"Close Window" action:@selector(performClose:) key:@"w" mods:C | S in:file target:nil];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = file;

    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [self item:@"Undo" action:@selector(undo:) key:@"z" mods:C in:edit target:nil];
    [self item:@"Redo" action:@selector(redo:) key:@"z" mods:C | S in:edit target:nil];
    [edit addItem:NSMenuItem.separatorItem];
    [self item:@"Cut" action:@selector(cut:) key:@"x" mods:C in:edit target:nil];
    [self item:@"Copy" action:@selector(copy:) key:@"c" mods:C in:edit target:nil];
    [self item:@"Paste" action:@selector(paste:) key:@"v" mods:C in:edit target:nil];
    [self item:@"Paste and Match Style" action:@selector(pasteAsPlainText:) key:@"v" mods:C | O | S in:edit target:nil];
    [self item:@"Select All" action:@selector(selectAll:) key:@"a" mods:C in:edit target:nil];
    [edit addItem:NSMenuItem.separatorItem];
    [self item:@"Find…" action:@selector(showFind:) key:@"f" mods:C in:edit target:nil];
    [self item:@"Find Next" action:@selector(findNext:) key:@"g" mods:C in:edit target:nil];
    [self item:@"Find Previous" action:@selector(findPrevious:) key:@"g" mods:C | S in:edit target:nil];
    [self item:@"Use Selection for Find" action:@selector(findSelection:) key:@"e" mods:C in:edit target:nil];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = edit;

    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    [self item:@"Reload Page" action:@selector(reloadOrStop:) key:@"r" mods:C in:view target:nil];
    [self item:@"Reload Ignoring Cache" action:@selector(hardReload:) key:@"r" mods:C | S in:view target:nil];
    [self item:@"Stop" action:@selector(stopLoading:) key:@"." mods:C in:view target:nil];
    [view addItem:NSMenuItem.separatorItem];
    [self item:@"Zoom In" action:@selector(zoomIn:) key:@"=" mods:C in:view target:nil];
    NSMenuItem *zp = [self item:@"Zoom In " action:@selector(zoomIn:) key:@"+" mods:C in:view target:nil]; zp.hidden = YES; zp.allowsKeyEquivalentWhenHidden = YES;
    [self item:@"Zoom Out" action:@selector(zoomOut:) key:@"-" mods:C in:view target:nil];
    [self item:@"Actual Size" action:@selector(zoomReset:) key:@"0" mods:C in:view target:nil];
    [view addItem:NSMenuItem.separatorItem];
    [self item:@"Toggle Sidebar" action:@selector(toggleSidebar:) key:@"s" mods:C in:view target:nil];
    [self item:@"Toggle Bookmarks Bar" action:@selector(toggleBookmarksBar:) key:@"b" mods:C | S in:view target:nil];
    [view addItem:NSMenuItem.separatorItem];
    [self item:@"Reader" action:@selector(toggleReader:) key:@"r" mods:C | K in:view target:nil];
    [view addItem:NSMenuItem.separatorItem];
    [self item:@"View Page Source" action:@selector(viewSource:) key:@"u" mods:C | O in:view target:nil];
    [self item:@"Downloads" action:@selector(showDownloadManager:) key:@"l" mods:C | O in:view target:nil];
    [self item:@"Picture in Picture" action:@selector(pictureInPicture:) key:@"p" mods:C | K in:view target:nil];
    [self item:@"Mute Tab" action:@selector(muteCurrent:) key:@"m" mods:C | K in:view target:nil];
    [self item:@"Enter Full Screen" action:@selector(toggleFullScreen:) key:@"f" mods:C | K in:view target:nil];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = view;

    NSMenu *dev = [[NSMenu alloc] initWithTitle:@"Develop"];
    [self item:@"Web Inspector" action:@selector(showInspector:) key:@"i" mods:C | O in:dev target:nil];
    [self item:@"JavaScript Console" action:@selector(showConsole:) key:@"j" mods:C | O in:dev target:nil];
    [self item:@"View Page Source" action:@selector(viewSource:) key:nil mods:0 in:dev target:nil];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = dev;

    NSMenu *hist = [[NSMenu alloc] initWithTitle:@"History"];
    [self item:@"Back" action:@selector(goBack:) key:@"[" mods:C in:hist target:nil];
    [self item:@"Forward" action:@selector(goForward:) key:@"]" mods:C in:hist target:nil];
    [hist addItem:NSMenuItem.separatorItem];
    [self item:@"Show All History" action:@selector(showHistory:) key:@"y" mods:C in:hist target:nil];
    [self item:@"Clear Browsing Data…" action:@selector(clearBrowsingData:) key:@"\b" mods:C | S in:hist target:nil];
    hist.delegate = self;   // recently closed tabs and recent pages fill in each time it opens
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = hist;

    NSMenu *bm = [[NSMenu alloc] initWithTitle:@"Bookmarks"];
    [self item:@"Bookmark This Page" action:@selector(toggleBookmark:) key:@"d" mods:C in:bm target:nil];
    [self item:@"Bookmark All Tabs" action:@selector(bookmarkAllTabs:) key:@"d" mods:C | S in:bm target:nil];
    [bm addItem:NSMenuItem.separatorItem];
    [self item:@"Show All Bookmarks" action:@selector(showBookmarks:) key:@"b" mods:C | O in:bm target:nil];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = bm;

    NSMenu *tabs = [[NSMenu alloc] initWithTitle:@"Tabs"];
    [self item:@"Next Tab" action:@selector(nextTab:) key:@"\t" mods:K in:tabs target:nil];
    [self item:@"Previous Tab" action:@selector(previousTab:) key:@"\t" mods:K | S in:tabs target:nil];
    NSMenuItem *n2 = [self item:@"Next Tab " action:@selector(nextTab:) key:@"]" mods:C | S in:tabs target:nil]; n2.hidden = YES; n2.allowsKeyEquivalentWhenHidden = YES;
    NSMenuItem *p2 = [self item:@"Previous Tab " action:@selector(previousTab:) key:@"[" mods:C | S in:tabs target:nil]; p2.hidden = YES; p2.allowsKeyEquivalentWhenHidden = YES;
    [tabs addItem:NSMenuItem.separatorItem];
    [self item:@"Pin Tab" action:@selector(pinCurrent:) key:@"p" mods:C | S in:tabs target:nil];
    [self item:@"Duplicate Tab" action:@selector(duplicateCurrent:) key:@"k" mods:C | S in:tabs target:nil];
    [self item:@"Close Other Tabs" action:@selector(closeOtherTabs:) key:@"w" mods:C | O in:tabs target:nil];
    [self item:@"Move Tab to New Window" action:@selector(moveCurrentToNewWindow:) key:nil mods:0 in:tabs target:nil];
    [self item:@"Split View" action:@selector(toggleSplit:) key:@"s" mods:C | K in:tabs target:nil];
    [self item:@"Swap Split Sides" action:@selector(swapSplit:) key:nil mods:0 in:tabs target:nil];
    [tabs addItem:NSMenuItem.separatorItem];
    [self item:@"Move Tab Up" action:@selector(moveTabLeft:) key:@"[" mods:C | K in:tabs target:nil];
    [self item:@"Move Tab Down" action:@selector(moveTabRight:) key:@"]" mods:C | K in:tabs target:nil];
    for (NSInteger i = 1; i <= 9; i++) {
        NSMenuItem *it = [self item:[NSString stringWithFormat:@"Tab %ld", (long)i] action:@selector(selectTabNumber:) key:[NSString stringWithFormat:@"%ld", (long)i] mods:C in:tabs target:nil];
        it.tag = i; it.hidden = YES; it.allowsKeyEquivalentWhenHidden = YES;
    }
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = tabs;

    NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
    [self item:@"Minimize" action:@selector(performMiniaturize:) key:@"m" mods:C in:win target:nil];
    [self item:@"Zoom" action:@selector(performZoom:) key:nil mods:0 in:win target:nil];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = win;
    NSApp.windowsMenu = win;
    NSApp.mainMenu = bar;
    [self aim:bar];
}

// The History menu, rebuilt as it opens: recently closed tabs, then the latest pages.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if ([menu.title isEqualToString:@"Profiles"]) {
        [menu removeAllItems];
        for (NSDictionary *p in Profiles()) {
            NSMenuItem *i = [menu addItemWithTitle:p[@"name"] action:@selector(openProfileItem:) keyEquivalent:@""]; i.target = self; i.representedObject = p[@"id"];
            i.image = ProfileAvatar(p[@"id"], p[@"name"], 16);
            i.state = gWin && !gWin.isPrivate && [gWin.profile isEqualToString:p[@"id"]] ? NSControlStateValueOn : NSControlStateValueOff;
        }
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItemWithTitle:@"New Profile…" action:@selector(newProfileAction:) keyEquivalent:@""].target = self;
        return;
    }
    if (![menu.title isEqualToString:@"History"]) return;
    while (menu.numberOfItems && [menu itemAtIndex:menu.numberOfItems - 1].tag == 77) [menu removeItemAtIndex:menu.numberOfItems - 1];
    NSMenuItem *(^add)(NSString *, SEL, id, NSString *) = ^NSMenuItem *(NSString *t, SEL a, id obj, NSString *url) {
        if (t.length > 70) t = [[t substringToIndex:69] stringByAppendingString:@"…"];
        NSMenuItem *i = [menu addItemWithTitle:t action:a keyEquivalent:@""]; i.tag = 77; i.target = gWin; i.representedObject = obj;
        NSImage *ic = url ? [VFavicons.shared iconForURL:url] : nil; if (ic) { NSImage *sm = [ic copy]; sm.size = NSMakeSize(16, 16); i.image = sm; }
        return i;
    };
    NSMenuItem *sep = NSMenuItem.separatorItem; sep.tag = 77; [menu addItem:sep];
    NSArray *closed = gWin.closed.reverseObjectEnumerator.allObjects;
    if (closed.count) {
        NSMenuItem *h = [menu addItemWithTitle:@"Recently Closed" action:nil keyEquivalent:@""]; h.tag = 77; h.enabled = NO;
        for (NSUInteger i = 0; i < MIN(10u, closed.count); i++) add([closed[i][@"title"] length] ? closed[i][@"title"] : closed[i][@"url"], @selector(reopenClosed:), closed[i], closed[i][@"url"]);
        NSMenuItem *s2 = NSMenuItem.separatorItem; s2.tag = 77; [menu addItem:s2];
    }
    NSArray *recent = gWin.isPrivate ? @[] : [VHistory.shared recent:15];
    if (recent.count) {
        NSMenuItem *h = [menu addItemWithTitle:@"Recently Visited" action:nil keyEquivalent:@""]; h.tag = 77; h.enabled = NO;
        for (NSDictionary *e in recent) add([e[@"ti"] length] ? e[@"ti"] : e[@"u"], @selector(openBookmarkItem:), e[@"u"], e[@"u"]);
    }
}

// New windows from the menu or the Dock.
// ⌘N opens a window in the profile you're using, as Chrome does
- (void)newWindow:(id)s { VWindow *w = [[VWindow alloc] initPrivate:NO state:@{@"profile": gWin && !gWin.isPrivate ? gWin.profile ?: @"" : @""}]; [w showWindow:nil]; [w windowDidResize:nil]; }
- (void)openProfileItem:(NSMenuItem *)i { OpenProfileWindow(i.representedObject); }
- (void)newProfileAction:(id)s { [gWin newProfile:nil]; }
- (void)newPrivateWindow:(id)s { VWindow *w = [[VWindow alloc] initPrivate:YES state:@{}]; [w showWindow:nil]; [w windowDidResize:nil]; }
- (NSMenu *)applicationDockMenu:(NSApplication *)a {
    NSMenu *m = [NSMenu new];
    [m addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"New Private Window" action:@selector(newPrivateWindow:) keyEquivalent:@""].target = self;
    return m;
}

// Window actions go straight to the active browser window instead of hunting the responder chain,
// so shortcuts work even while focus sits in the address bar or a popup.
- (void)aim:(NSMenu *)m {
    for (NSMenuItem *it in m.itemArray) {
        if (it.submenu) [self aim:it.submenu];
        else if (!it.target && it.action && [VWindow instancesRespondToSelector:it.action] &&
                 ![@[@"cut:", @"copy:", @"paste:", @"pasteAsPlainText:", @"selectAll:", @"undo:", @"redo:", @"performClose:", @"performMiniaturize:", @"performZoom:", @"toggleFullScreen:"] containsObject:NSStringFromSelector(it.action)])
            it.target = VWinProxy.shared;
    }
}

@end

static void OnException(NSException *e) { DLog(@"EXCEPTION %@ %@\n%@", e.name, e.reason, e.callStackSymbols); }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        NSSetUncaughtExceptionHandler(&OnException);
        [Defaults() registerDefaults:@{@"NSApplicationCrashOnExceptions": @YES}];
        gApp = [VApp new];
        app.delegate = gApp;
        [app run];
    }
    return 0;
}

#pragma mark - Settings as a page (flint://settings)

// The page asks for the whole settings layout (sections → groups → rows, with current values) and sends back
// changes and button presses by row id. Every row is described here once, with the code that applies it, so the
// page stays a plain renderer. The layout is rebuilt for every request: values and lists are always current.

typedef void (^SSetter)(id value);
typedef void (^SAction)(NSDictionary *args, void (^done)(NSString *toast));
static NSMutableDictionary<NSString *, SSetter> *gSSet;
static NSMutableDictionary<NSString *, SAction> *gSAct;
static BOOL gSettingsNeedRelaunch;

static NSMutableDictionary *SRow(NSString *type, NSString *ident, NSString *title, NSString *detail) {
    NSMutableDictionary *r = [@{@"type": type, @"id": ident ?: @"", @"title": title ?: @""} mutableCopy];
    if (detail.length) r[@"detail"] = detail;
    return r;
}
static NSDictionary *SSwitch(NSString *ident, NSString *title, NSString *detail, BOOL on, SSetter set) {
    gSSet[ident] = set; NSMutableDictionary *r = SRow(@"switch", ident, title, detail); r[@"value"] = @(on); return r;
}
// a switch bound straight to a stored setting, with what to do after it changes
static NSDictionary *SKey(NSString *key, NSString *title, NSString *detail, BOOL invert, void (^after)(void)) {
    BOOL v = [Defaults() boolForKey:key]; if (invert) v = !v;
    return SSwitch(key, title, detail, v, ^(id value) { BOOL b = [value boolValue]; [Defaults() setBool:invert ? !b : b forKey:key]; if (after) after(); });
}
static NSDictionary *SSelect(NSString *ident, NSString *title, NSString *detail, NSArray<NSString *> *labels, NSInteger sel, void (^set)(NSInteger)) {
    gSSet[ident] = ^(id v) { NSInteger i = [v integerValue]; if (i >= 0 && i < (NSInteger)labels.count) set(i); };
    NSMutableDictionary *r = SRow(@"select", ident, title, detail); r[@"options"] = labels; r[@"value"] = @(MAX(0, MIN((NSInteger)labels.count - 1, sel))); return r;
}
static NSMutableDictionary *SButton(NSString *ident, NSString *title, NSString *detail, NSString *label, SAction act) {
    gSAct[ident] = act; NSMutableDictionary *r = SRow(@"button", ident, title, detail); r[@"label"] = label; return r;
}
static NSDictionary *SValue(NSString *title, NSString *detail, NSString *text) { NSMutableDictionary *r = SRow(@"value", @"", title, detail); if (text) r[@"value"] = text; return r; }
static NSDictionary *SNote(NSString *title, NSString *detail) { return SRow(@"note", @"", title, detail); }
static NSDictionary *SGroup(NSString *title, NSArray *rows) { return title ? @{@"title": title, @"rows": rows} : @{@"rows": rows}; }
static NSDictionary *SSection(NSString *ident, NSString *title, NSString *subtitle, NSString *icon, NSArray *groups) {
    return @{@"id": ident, @"title": title, @"subtitle": subtitle ?: @"", @"icon": icon, @"groups": groups};
}
static NSString *PNGDataURL(NSImage *im, CGFloat size) {
    if (!im) return nil;
    NSImage *s = [NSImage imageWithSize:NSMakeSize(size, size) flipped:NO drawingHandler:^BOOL(NSRect r) { [im drawInRect:r]; return YES; }];
    CGImageRef cg = [s CGImageForProposedRect:NULL context:nil hints:nil]; if (!cg) return nil;
    NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:cg] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];
}
static void RelayoutAll(void) { for (VWindow *w in gWindows) { [w.sidebar reload]; [w layout]; [w.toolbar layoutBar]; [w refreshChrome]; } }

static NSArray *SettingsSchema(VWindow *win) {
    gSSet = [NSMutableDictionary dictionary]; gSAct = [NSMutableDictionary dictionary];
    NSMutableArray *S = [NSMutableArray array];

    // ── General
    BOOL isDefault = [[[NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com"]] URLByStandardizingPath].path isEqualToString:NSBundle.mainBundle.bundleURL.URLByStandardizingPath.path];
    NSArray *mins = @[@5, @10, @30, @60, @0];
    NSUInteger si = [mins indexOfObject:@([Defaults() integerForKey:kSleepMins])]; if (si == NSNotFound) si = 1;
    NSArray *zs = @[@0.75, @0.9, @1.0, @1.1, @1.25, @1.5];
    double zcur = [Defaults() objectForKey:kDefaultZoom] ? [Defaults() doubleForKey:kDefaultZoom] : 1.0;
    NSInteger zi = 2; for (NSUInteger k = 0; k < zs.count; k++) if (fabs([zs[k] doubleValue] - zcur) < 0.01) zi = (NSInteger)k;
    NSUInteger ownZoom = [Defaults() dictionaryForKey:kZoom].count;
    [S addObject:SSection(@"general", @"General", @"How Flint starts and how it treats your tabs.", @"gear", @[
        SGroup(@"Default browser", @[ isDefault ? SValue(@"Flint is your default browser", @"Links you click in other apps open here.", @"✓")
            : SButton(@"makeDefault", @"Flint isn't your default browser", @"Links you click in other apps open here.", @"Make Default", ^(NSDictionary *a, void (^done)(NSString *)) {
                NSURL *me = NSBundle.mainBundle.bundleURL;
                [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:me toOpenURLsWithScheme:@"http" completionHandler:^(NSError *e) {
                    [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:me toOpenURLsWithScheme:@"https" completionHandler:^(NSError *e2) { dispatch_async(dispatch_get_main_queue(), ^{ done(nil); }); }];
                }];
            }) ]),
        SGroup(@"Startup", @[ SSelect(@"startup", @"When Flint opens", nil, @[@"Continue where you left off", @"Open a new tab"], [Defaults() integerForKey:kStartup], ^(NSInteger i) { [Defaults() setInteger:i forKey:kStartup]; }) ]),
        SGroup(@"Tabs", @[
            SSelect(@"sleep", @"Put background tabs to sleep", @"Sleeping tabs free their memory and wake instantly when you return to them.", @[@"After 5 minutes", @"After 10 minutes", @"After 30 minutes", @"After 1 hour", @"Never"], (NSInteger)si,
                    ^(NSInteger i) { [Defaults() setInteger:[mins[(NSUInteger)i] integerValue] forKey:kSleepMins]; }),
            SKey(kAutoPiP, @"Float playing videos when you switch tabs", @"A video that’s playing moves to picture in picture while you’re on another tab, and back when you return.", NO, nil) ]),
        SGroup(@"Page zoom", @[
            SSelect(@"zoom", @"Default zoom", @"Sites you've zoomed individually keep their own level.", @[@"75%", @"90%", @"100%", @"110%", @"125%", @"150%"], zi, ^(NSInteger i) {
                double z = [zs[(NSUInteger)i] doubleValue]; [Defaults() setDouble:z forKey:kDefaultZoom];
                NSDictionary *own = [Defaults() dictionaryForKey:kZoom];
                for (VTab *t in AllTabs(YES)) if (t.web && !own[HostOf([NSURL URLWithString:t.url ?: @""])]) [t.web setZoomLevel:z];
            }),
            ownZoom ? SButton(@"resetZooms", @"Sites with their own zoom", nil, [NSString stringWithFormat:@"Reset %lu", (unsigned long)ownZoom], ^(NSDictionary *a, void (^done)(NSString *)) { [Defaults() removeObjectForKey:kZoom]; done(@"Zoom reset on every site"); })
                    : SValue(@"Sites with their own zoom", nil, @"None") ]),
        SGroup(@"Quitting", @[ SKey(kConfirmQuit, @"Ask before quitting with several tabs open", nil, NO, nil) ])
    ])];

    // ── Appearance
    NSMutableArray *accents = [NSMutableArray array];
    for (NSArray *a in Accents()) { NSColor *c = [Hex((uint32_t)[a[1] unsignedIntValue]) colorUsingColorSpace:NSColorSpace.sRGBColorSpace]; [accents addObject:@{@"label": a[0], @"color": [NSString stringWithFormat:@"#%02x%02x%02x", (int)lround(c.redComponent * 255), (int)lround(c.greenComponent * 255), (int)lround(c.blueComponent * 255)]}]; }
    NSMutableDictionary *accentRow = SRow(@"swatches", @"accent", @"Accent colour", @"Used for the loading bar, the active tab and highlights.");
    accentRow[@"options"] = accents; accentRow[@"value"] = @([Defaults() integerForKey:kAccent]);
    gSSet[@"accent"] = ^(id v) { [Defaults() setInteger:[v integerValue] forKey:kAccent]; FlintApplyTheme(); };
    NSMutableArray *tb = [NSMutableArray array];
    for (NSArray *b in @[@[@"sidebar", @"Sidebar"], @[@"back", @"Back"], @[@"forward", @"Forward"], @[@"reload", @"Reload"], @[@"home", @"Home"], @[@"star", @"Bookmark star"],
                          @[@"reader", @"Reader"], @[@"share", @"Share"], @[@"newtab", @"New tab"], @[@"dlalways", @"Downloads, always"], @[@"extensions", @"Extensions menu"], @[@"shield", @"Ad blocking shield"]]) {
        NSString *k = b[0];
        [tb addObject:SSwitch([@"tb." stringByAppendingString:k], b[1], nil, ToolbarShows(k), ^(id v) { SetToolbarShows(k, [v boolValue]); RelayoutAll(); })];
    }
    NSArray *fonts = @[@0, @9, @10, @11, @12, @14, @16];
    NSUInteger mi = [fonts indexOfObject:@([Defaults() integerForKey:kMinFont])]; if (mi == NSNotFound) mi = 0;
    [S addObject:SSection(@"appearance", @"Appearance", @"Make Flint look the way you want. Changes apply instantly.", @"brush", @[
        SGroup(@"Theme", @[
            SSelect(@"theme", @"Theme", @"Carbon is near-black, like Flint's icon. Pages follow light or dark where they support it.", @[@"Follow macOS", @"Graphite", @"Carbon", @"Light"], [Defaults() integerForKey:kTheme],
                    ^(NSInteger i) { [Defaults() setInteger:i forKey:kTheme]; FlintApplyTheme(); }),
            accentRow,
            SSelect(@"density", @"Density", @"How much room each tab gets in the sidebar.", @[@"Compact", @"Comfortable", @"Roomy"], [Defaults() integerForKey:kDensity], ^(NSInteger i) { [Defaults() setInteger:i forKey:kDensity]; RelayoutAll(); }) ]),
        SGroup(@"Layout", @[
            SKey(kSidebarHidden, @"Show the tab sidebar", @"⌘S toggles it at any time.", YES, ^{ RelayoutAll(); }),
            SKey(kSidebarRight, @"Sidebar on the right", nil, NO, ^{ RelayoutAll(); }),
            SKey(kShowBookmarks, @"Show the bookmarks bar", @"⇧⌘B toggles it at any time.", NO, ^{ RelayoutAll(); }) ]),
        SGroup(@"Toolbar", [@[ SSelect(@"addrWidth", @"Address bar width", @"Right-click the toolbar to change these right where they are.", @[@"Full", @"Medium", @"Compact"], [Defaults() integerForKey:kAddrWidth],
                                      ^(NSInteger i) { [Defaults() setInteger:i forKey:kAddrWidth]; RelayoutAll(); }) ] arrayByAddingObjectsFromArray:tb]),
        SGroup(@"New tab page", @[ SKey(kHomeTopSites, @"Show your most visited sites", nil, NO, ^{ RelayoutAll(); }) ]),
        SGroup(@"Text", @[ SSelect(@"minFont", @"Minimum font size", @"Tiny text on pages is enlarged to at least this size. Applies to pages you open next.", @[@"None", @"9 pt", @"10 pt", @"11 pt", @"12 pt", @"14 pt", @"16 pt"], (NSInteger)mi,
                                   ^(NSInteger i) { [Defaults() setInteger:[fonts[(NSUInteger)i] integerValue] forKey:kMinFont]; }) ])
    ])];

    // ── Search
    NSMutableArray *engines = [NSMutableArray array]; for (NSArray *e in Engines()) [engines addObject:e[0]];
    NSArray *ce = [Defaults() arrayForKey:kCustomEngine];
    NSMutableDictionary *custom = SButton(@"customEngine", ce.count == 2 ? [NSString stringWithFormat:@"Custom: %@", ce[0]] : @"Add your own search engine",
        @"Any site that searches with a web address, like https://example.com/search?q=%s", ce.count == 2 ? @"Edit…" : @"Add…", ^(NSDictionary *a, void (^done)(NSString *)) {
            if ([a[@"remove"] boolValue]) { [Defaults() removeObjectForKey:kCustomEngine]; [Defaults() setInteger:0 forKey:kSearch]; done(@"Custom search engine removed"); return; }
            NSString *n = Trim([a[@"name"] description] ?: @""), *u = Trim([a[@"url"] description] ?: @"");
            if (!n.length || ![u containsString:@"%s"] || ![u hasPrefix:@"http"]) { done(@"Needs a name and an address containing %s"); return; }
            [Defaults() setObject:@[n, [u stringByReplacingOccurrencesOfString:@"%s" withString:@"%@"]] forKey:kCustomEngine];
            [Defaults() setInteger:(NSInteger)Engines().count - 1 forKey:kSearch];
            done(@"Search engine saved");
        });
    custom[@"prompt"] = @{@"title": @"Custom search engine", @"text": @"Use %s where the search words go.", @"ok": @"Save", @"remove": ce.count == 2 ? @"Remove" : @"",
                          @"fields": @[@{@"name": @"name", @"placeholder": @"Name, e.g. Wikipedia", @"value": ce.count == 2 ? ce[0] : @""},
                                       @{@"name": @"url", @"placeholder": @"https://en.wikipedia.org/w/index.php?search=%s", @"value": ce.count == 2 ? [ce[1] stringByReplacingOccurrencesOfString:@"%@" withString:@"%s"] : @""}]};
    [S addObject:SSection(@"search", @"Search", @"Used when you type something that isn't an address.", @"search", @[
        SGroup(nil, @[ SSelect(@"engine", @"Search with", nil, engines, [Defaults() integerForKey:kSearch], ^(NSInteger i) { [Defaults() setInteger:i forKey:kSearch]; RelayoutAll(); }), custom ]),
        SGroup(@"Suggestions", @[ SValue(@"History, bookmarks and open tabs", @"Matched on this Mac.", @"Always"),
            SKey(kSuggestNet, [NSString stringWithFormat:@"Suggestions from %@", Engine()[0]], @"What you type in the address bar is sent to your search engine (without cookies) to suggest searches. Turn off to keep typing entirely on this Mac.", NO, nil) ])
    ])];

    // ── Privacy & Security
    NSMutableDictionary *manage = SButton(@"manageData", @"Cookies and website data", @"See which sites store data on this Mac and remove it.", @"Manage…", ^(NSDictionary *a, void (^done)(NSString *)) { done(nil); });
    manage[@"dataManager"] = @YES;
    [S addObject:SSection(@"privacy", @"Privacy & Security", @"Flint sends nothing to advertisers, and your data stays on this Mac.", @"hand", @[
        SGroup(@"Tracking", @[
            SKey(kBlock, @"Block ads and trackers", @"Requests to known ad and tracking servers are never made.", NO, ^{ FlintSetBlocking([Defaults() boolForKey:kBlock]); for (VWindow *w in gWindows) [w refreshChrome]; }),
            SKey(kStrip, @"Remove tracking tags from links", @"Strips utm_, fbclid, gclid and similar parameters before a page loads.", NO, nil),
            SKey(kCookieReject, @"Reject cookie banners", @"Answers consent pop-ups with “Reject all” on sites that offer it. Turning the shield off for a site skips it there.", NO, nil),
            SValue(@"Prevent cross-site tracking", @"WebKit's Intelligent Tracking Prevention limits cookies that follow you between sites.", @"Always on"),
            SKey(kGPC, @"Ask sites not to sell or share my data", @"Sends the Global Privacy Control signal. Applies to pages you open next.", NO, nil) ]),
        SGroup(@"Security", @[
            SKey(kHTTPSOnly, @"HTTPS-only mode", @"Tries every site over a secure connection and warns you before opening one that isn't.", NO, nil),
            SValue(@"Fraudulent website warnings", @"Off: it would send the addresses you visit to Google Safe Browsing.", @"Off") ]),
        SGroup(@"Your data", @[
            SButton(@"clearData", @"Browsing history", @"Used for address-bar suggestions; never leaves this Mac.", @"Clear History…", ^(NSDictionary *a, void (^done)(NSString *)) { [win clearBrowsingData:nil]; done(nil); }),
            manage,
            SKey(kClearOnQuit, @"Clear cookies and website data when Flint quits", @"You'll be signed out of sites each time.", NO, nil) ])
    ])];

    // ── Site settings
    NSMutableArray *js = [NSMutableArray arrayWithObject:SKey(kScripts, @"Allow JavaScript", @"Lets pages run scripts. Most sites need it.", NO, ^{ [gWin.current.web reload]; })];
    NSArray *off = [Defaults() arrayForKey:kJSOff] ?: @[];
    if (!off.count) [js addObject:SNote(@"No sites with JavaScript turned off", nil)];
    for (NSString *h in off) [js addObject:SButton([@"jsoff." stringByAppendingString:h], h, @"JavaScript off", @"Remove", ^(NSDictionary *a, void (^done)(NSString *)) {
        NSMutableArray *l = [[Defaults() arrayForKey:kJSOff] ?: @[] mutableCopy]; [l removeObject:h]; [Defaults() setObject:l forKey:kJSOff]; done(nil); })];
    NSMutableArray *cam = [NSMutableArray array];
    NSDictionary *perms = [Defaults() dictionaryForKey:kSitePerms] ?: @{};
    if (!perms.count) [cam addObject:SNote(@"No decisions yet", @"Sites ask the first time they want your camera or microphone.")];
    for (NSString *h in [perms.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSMutableArray *bits = [NSMutableArray array];
        for (NSString *k in @[@"camera", @"microphone"]) { NSInteger v = [perms[h][k] integerValue]; if (v) [bits addObject:[NSString stringWithFormat:@"%@ %@", k.capitalizedString, v == 1 ? @"allowed" : @"blocked"]]; }
        [cam addObject:SButton([@"perm." stringByAppendingString:h], h, [bits componentsJoinedByString:@" · "], @"Reset", ^(NSDictionary *a, void (^done)(NSString *)) {
            NSMutableDictionary *d = [[Defaults() dictionaryForKey:kSitePerms] ?: @{} mutableCopy]; [d removeObjectForKey:h]; [Defaults() setObject:d forKey:kSitePerms]; done(nil); })];
    }
    NSMutableArray *allowRows = [NSMutableArray array];
    NSArray *allow = [Defaults() arrayForKey:kAllowlist] ?: @[];
    if (!allow.count) [allowRows addObject:SNote(@"Blocking is on for every site", nil)];
    for (NSString *h in allow) [allowRows addObject:SButton([@"allow." stringByAppendingString:h], h, @"Blocking turned off", @"Turn Back On", ^(NSDictionary *a, void (^done)(NSString *)) {
        NSMutableArray *l = [[Defaults() arrayForKey:kAllowlist] ?: @[] mutableCopy]; [l removeObject:h]; [Defaults() setObject:l forKey:kAllowlist]; FlintReloadBlocklists(); done(nil); })];
    [S addObject:SSection(@"sites", @"Site Settings", @"Choices you've made for individual sites. Change them from the lock icon in the address bar.", @"sliders", @[
        SGroup(@"JavaScript", js), SGroup(@"Camera and microphone", cam), SGroup(@"Ad blocking", allowRows) ])];

    // ── Ad blocking
    NSMutableArray *lists = [NSMutableArray array]; NSSet *on = ListsOn();
    for (NSArray *l in FilterLists()) {
        NSString *k = l[0];
        [lists addObject:SSwitch([@"list." stringByAppendingString:k], l[1], nil, [on containsObject:k], ^(id v) {
            NSMutableSet *s = [ListsOn() mutableCopy]; if ([v boolValue]) [s addObject:k]; else [s removeObject:k];
            [Defaults() setObject:s.allObjects forKey:kListsOn]; [VBlocker.shared updateLists:NO done:nil]; })];
    }
    [S addObject:SSection(@"blocking", @"Ad Blocking", @"Filter lists Flint uses to recognise ad and tracker servers. They update themselves weekly.", @"shield", @[
        SGroup(@"Lists", lists),
        SGroup(@"Updates", @[ SValue(@"Status", nil, VBlocker.shared.status ?: @""),
            SButton(@"updateLists", @"Update the lists now", nil, @"Update Now", ^(NSDictionary *a, void (^done)(NSString *)) { [win updateListsNow:nil]; done(@"Updating filter lists…"); }) ]) ])];

    // ── Performance
    BOOL arm = MacIsAppleSilicon();
    [S addObject:SSection(@"performance", @"Performance", @"Engine-level controls that change how much work your Mac does.", @"gauge", @[
        SGroup(@"Video", @[
            SSelect(@"codec", @"Video format", arm ? @"Apple silicon decodes H.264, VP9 and (on newer chips) AV1 in hardware, so Automatic is usually best here. Applies to pages you open or reload."
                                                   : @"This Mac's Intel chip decodes H.264 in hardware; VP9 and AV1 fall back to the processor, which costs battery, heat and fan noise. H.264 tops out at 1080p on YouTube. Applies to pages you open or reload.",
                    @[@"Automatic", @"Avoid AV1", @"H.264 only"], [Defaults() integerForKey:kCodec], ^(NSInteger i) { [Defaults() setInteger:i forKey:kCodec]; FlintCodecChanged(); }),
            SKey(kCodec30, @"Limit videos to 30 fps", @"Turns down 60 fps streams: half the frames to decode. Sports and games look less smooth.", NO, ^{ FlintCodecChanged(); }) ]),
        SGroup(@"Engine", @[
            SSelect(@"bgThrottle", @"Background tabs", @"Saving power slows a hidden tab's timers further the longer it stays hidden, as Safari does. Music and calls keep playing.",
                    @[@"Standard", @"Save power on battery", @"Always save power"], [Defaults() integerForKey:kBgThrottle], ^(NSInteger i) { [Defaults() setInteger:i forKey:kBgThrottle]; [gApp applyThrottleNow]; }),
            SKey(kSingleProcess, @"One process for all tabs", @"Saves a lot of memory with many tabs open. If one tab crashes, all of them reload. Takes effect when Flint restarts.", NO, nil),
            SValue(@"Processor use", @"Flint and its helpers average at most one core over any 10 seconds; short bursts run at full speed, and sound and video are never slowed.", @"Always on") ]),
        SGroup(@"Launch", @[
            SKey(kRestorePaused, @"Restored video starts paused", @"The tab you were on comes back without playing by itself.", NO, nil),
            SKey(kResumeMedia, @"Videos resume where you left off", @"After a restart, a reopened tab or a sleeping tab waking, the video picks up at the same moment.", NO, nil),
            SKey(kLazyRestore, @"Load the open tab when you click it", @"At launch, the tab you were on waits as a card until you click it, so nothing loads until you want it.", NO, nil) ])
    ])];

    // ── Extensions
    NSMutableArray *exts = [NSMutableArray array];
    for (NSDictionary *e in FExtHost.shared.allExtensionInfo) {
        NSString *ident = e[@"ident"];
        NSMutableDictionary *r = SRow(@"extension", [@"ext." stringByAppendingString:ident], e[@"name"], [NSString stringWithFormat:@"Version %@ · %@", e[@"version"], ident]);
        r[@"value"] = e[@"enabled"] ?: @NO;
        NSString *icon = [e[@"icon"] isKindOfClass:NSImage.class] ? PNGDataURL(e[@"icon"], 56) : nil; if (icon) r[@"icon"] = icon;
        gSSet[r[@"id"]] = ^(id v) { [FExtHost.shared setExtension:ident enabled:[v boolValue]]; gSettingsNeedRelaunch = YES; };
        gSAct[[@"extrm." stringByAppendingString:ident]] = ^(NSDictionary *a, void (^done)(NSString *)) { [FExtHost.shared removeExtension:ident]; gSettingsNeedRelaunch = YES; done(@"Extension moved to the Trash"); };
        if ([FExtHost.shared hasOptionsForID:ident]) { r[@"options"] = @YES; gSAct[[@"extopt." stringByAppendingString:ident]] = ^(NSDictionary *a, void (^done)(NSString *)) { [FExtHost.shared openOptionsForID:ident]; done(nil); }; }
        [exts addObject:r];
    }
    if (!exts.count) [exts addObject:SNote(@"No extensions yet", nil)];
    NSMutableDictionary *install = SButton(@"installExt", @"Install from the Chrome Web Store", @"Paste the extension's Web Store link.", @"Install…", ^(NSDictionary *a, void (^done)(NSString *)) {
        NSString *link = Trim([a[@"url"] description] ?: @""); if (!link.length) { done(nil); return; }
        [win showToast:@"Installing extension…"];
        [FExtHost.shared installFromWebStore:link done:^(NSString *name, NSString *err) {
            if (!err) gSettingsNeedRelaunch = YES;
            done(err ? [@"Couldn't install: " stringByAppendingString:err] : [NSString stringWithFormat:@"%@ installed — relaunch to start it", name ?: @"Extension"]);
        }];
    });
    install[@"prompt"] = @{@"title": @"Install from the Chrome Web Store", @"text": @"Paste the extension's page address from chromewebstore.google.com.", @"ok": @"Install",
                           @"fields": @[@{@"name": @"url", @"placeholder": @"https://chromewebstore.google.com/detail/…", @"value": @""}]};
    NSMutableArray *add = [NSMutableArray arrayWithObjects:install,
        SButton(@"extFolder", @"Extensions folder", @"Unpacked extensions placed here load at launch.", @"Open", ^(NSDictionary *a, void (^done)(NSString *)) { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:ExtRoot()]]; done(nil); }), nil];
    if (gSettingsNeedRelaunch) [add addObject:SButton(@"relaunch", @"Restart Flint to apply extension changes", @"Your tabs come back.", @"Relaunch Now", ^(NSDictionary *a, void (^done)(NSString *)) {
        for (VWindow *w in gWindows) if (!w.isPrivate) { [w saveSession]; break; }
        [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:@[@"-c", [NSString stringWithFormat:@"sleep 1.2; open \"%@\"", NSBundle.mainBundle.bundlePath]]];
        [NSApp terminate:nil]; })];
    [S addObject:SSection(@"extensions", @"Extensions", @"Chrome extensions running on Flint's own extension layer.", @"puzzle", @[ SGroup(@"Installed", exts), SGroup(@"Add", add) ])];

    // ── Downloads
    NSString *dir = [Defaults() stringForKey:kDownloadDir];
    NSArray *limits = @[@0, @256, @512, @1024, @2048, @5120, @10240];
    NSUInteger li = [limits indexOfObject:@([Defaults() integerForKey:kDLLimit])]; if (li == NSNotFound) li = 0;
    NSArray *conns = @[@1, @2, @4, @6, @8, @12, @16], *actives = @[@1, @2, @3, @4, @5, @6, @8];
    NSUInteger ai = [actives indexOfObject:@([Defaults() integerForKey:kDLActive])]; if (ai == NSNotFound) ai = 2;
    NSUInteger ci = [conns indexOfObject:@([Defaults() integerForKey:kDLConns])]; if (ci == NSNotFound) ci = 4;
    [S addObject:SSection(@"downloads", @"Downloads", @"Where files go, and how Flint fetches them.", @"download", @[
        SGroup(@"Location", @[
            SButton(@"chooseDownloads", dir.length ? dir.stringByAbbreviatingWithTildeInPath : @"~/Downloads", @"Current download folder", @"Change…", ^(NSDictionary *a, void (^done)(NSString *)) {
                NSOpenPanel *p = [NSOpenPanel openPanel]; p.canChooseDirectories = YES; p.canChooseFiles = NO; p.canCreateDirectories = YES; p.prompt = @"Use Folder";
                [p beginSheetModalForWindow:win.window completionHandler:^(NSModalResponse r) { if (r == NSModalResponseOK && p.URL) [Defaults() setObject:p.URL.path forKey:kDownloadDir]; done(nil); }];
            }),
            SKey(kAskDownload, @"Ask where to save each file", @"Uses the standard save sheet (one connection).", NO, nil),
            SButton(@"openDownloads", @"Show the download folder", nil, @"Open", ^(NSDictionary *a, void (^done)(NSString *)) { [NSWorkspace.sharedWorkspace openURL:win.downloadFolder]; done(nil); }),
            SButton(@"downloadManager", @"Download manager", @"Every download, with speed, slices and controls. ⌥⌘L", @"Open", ^(NSDictionary *a, void (^done)(NSString *)) { [win showDownloadManager:nil]; done(nil); }) ]),
        SGroup(@"Accelerator", @[
            SKey(kDLAccel, @"Download with several connections", @"Like Internet Download Manager: a file is fetched in slices at once, and can be paused and resumed, even after quitting.", NO, nil),
            SSelect(@"dlConns", @"Connections per download", nil, @[@"1", @"2", @"4", @"6", @"8", @"12", @"16"], (NSInteger)ci, ^(NSInteger i) { [Defaults() setInteger:[conns[(NSUInteger)i] integerValue] forKey:kDLConns]; }),
            SSelect(@"dlActive", @"Downloads at the same time", @"The rest wait in line.", @[@"1", @"2", @"3", @"4", @"5", @"6", @"8"], (NSInteger)ai,
                    ^(NSInteger i) { [Defaults() setInteger:[actives[(NSUInteger)i] integerValue] forKey:kDLActive]; }),
            SSelect(@"dlLimit", @"Speed limit", @"For all downloads together.", @[@"No limit", @"256 KB/s", @"512 KB/s", @"1 MB/s", @"2 MB/s", @"5 MB/s", @"10 MB/s"], (NSInteger)li,
                    ^(NSInteger i) { [Defaults() setInteger:[limits[(NSUInteger)i] integerValue] forKey:kDLLimit]; }) ])
    ])];

    // ── Profiles
    NSMutableArray *profRows = [NSMutableArray array];
    for (NSDictionary *p in Profiles()) {
        NSString *pid = p[@"id"];
        NSUInteger open = 0; for (VWindow *w in gWindows) if (!w.isPrivate && [w.profile isEqualToString:pid]) open++;
        NSString *detail = [NSString stringWithFormat:@"%@%@", pid.length ? @"Its own sign-ins, cookies, history and tabs" : @"The first profile",
                            open ? [NSString stringWithFormat:@" · %lu window%@ open", (unsigned long)open, open == 1 ? @"" : @"s"] : @""];
        NSMutableDictionary *row = SButton([@"prof." stringByAppendingString:pid.length ? pid : @"main"], p[@"name"], detail, @"Rename…", ^(NSDictionary *a, void (^done)(NSString *)) {
            if ([a[@"remove"] boolValue] && pid.length) {
                BOOL others = NO; for (VWindow *w in gWindows) if (w.isPrivate || ![w.profile isEqualToString:pid]) others = YES;
                if (!others) OpenProfileWindow(@"");   // never close Flint's last window
                for (VWindow *w in gWindows.copy) if (!w.isPrivate && [w.profile isEqualToString:pid]) [w.window performClose:nil];
                NSMutableArray *all = [[Defaults() arrayForKey:kProfiles] ?: @[] mutableCopy];
                [all filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *x, NSDictionary *b) { return ![x[@"id"] isEqualToString:pid]; }]];
                [Defaults() setObject:all forKey:kProfiles];
                [NSFileManager.defaultManager removeItemAtPath:SupportFile([NSString stringWithFormat:@"history-%@.json", pid]) error:nil];
                [gProfileStores removeObjectForKey:pid];
                if (@available(macOS 14.0, *)) {   // its website data goes too (once its pages have closed)
                    NSUUID *u = [[NSUUID alloc] initWithUUIDString:pid];
                    if (u) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [WKWebsiteDataStore removeDataStoreForIdentifier:u completionHandler:^(NSError *e) { if (e) DLog(@"profile data not removed: %@", e.localizedDescription); }]; });
                }
                RelayoutAll(); done(@"Profile deleted"); return;
            }
            NSString *n = Trim([a[@"name"] description] ?: @""); if (!n.length) { done(@"Needs a name"); return; }
            if (!pid.length) [Defaults() setObject:n forKey:kMainProfileName];
            else {
                NSMutableArray *all = [NSMutableArray array];
                for (NSDictionary *x in [Defaults() arrayForKey:kProfiles] ?: @[]) { NSMutableDictionary *m = [x mutableCopy]; if ([x[@"id"] isEqualToString:pid]) m[@"name"] = n; [all addObject:m]; }
                [Defaults() setObject:all forKey:kProfiles];
            }
            for (VWindow *w in gWindows) if (!w.isPrivate && [w.profile isEqualToString:pid]) w.window.title = pid.length ? [@"Flint · " stringByAppendingString:n] : @"Flint";
            RelayoutAll(); done(@"Profile renamed");
        });
        row[@"prompt"] = @{@"title": @"Profile", @"text": pid.length ? @"Deleting a profile closes its windows and erases its sign-ins, cookies and history." : @"The first profile can be renamed but not deleted.",
                           @"ok": @"Save", @"remove": pid.length ? @"Delete Profile" : @"", @"fields": @[@{@"name": @"name", @"placeholder": @"Name", @"value": p[@"name"]}]};
        row[@"icon"] = PNGDataURL(ProfileAvatar(pid, p[@"name"], 40), 40);
        NSString *openId = [@"profopen." stringByAppendingString:pid.length ? pid : @"main"];
        gSAct[openId] = ^(NSDictionary *a, void (^done)(NSString *)) { OpenProfileWindow(pid); done(nil); };
        row[@"more"] = @[@{@"id": openId, @"label": @"Open"}];
        [profRows addObject:row];
        // its colour: the avatar, the badge's outline and the window's tint
        NSMutableArray *opts = [NSMutableArray array];
        for (NSArray *c in ProfileColors()) { NSColor *x = [Hex((uint32_t)[c[1] unsignedIntValue]) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            [opts addObject:@{@"label": c[0], @"color": [NSString stringWithFormat:@"#%02x%02x%02x", (int)lround(x.redComponent * 255), (int)lround(x.greenComponent * 255), (int)lround(x.blueComponent * 255)]}]; }
        NSString *colorId = [@"profcolor." stringByAppendingString:pid.length ? pid : @"main"];
        NSMutableDictionary *sw = SRow(@"swatches", colorId, [NSString stringWithFormat:@"%@'s colour", p[@"name"]], nil);
        sw[@"options"] = opts; sw[@"value"] = @(ProfileColorIndex(pid));
        gSSet[colorId] = ^(id v) {
            NSInteger ci = [v integerValue]; if (ci < 0 || ci >= (NSInteger)ProfileColors().count) return;
            if (!pid.length) [Defaults() setInteger:ci forKey:kMainProfileColor];
            else {
                NSMutableArray *all = [NSMutableArray array];
                for (NSDictionary *x in [Defaults() arrayForKey:kProfiles] ?: @[]) { NSMutableDictionary *m = [x mutableCopy]; if ([x[@"id"] isEqualToString:pid]) m[@"color"] = @(ci); [all addObject:m]; }
                [Defaults() setObject:all forKey:kProfiles];
            }
            RelayoutAll();
        };
        [profRows addObject:sw];
    }
    NSMutableDictionary *newProf = SButton(@"profNew", @"New profile", @"For work, study or anything you keep apart. Bookmarks and extensions are shared.", @"Add…", ^(NSDictionary *a, void (^done)(NSString *)) {
        NSString *n = Trim([a[@"name"] description] ?: @"");
        OpenProfileWindow(CreateProfile(n)); RelayoutAll(); done(@"Profile created");
    });
    newProf[@"prompt"] = @{@"title": @"New profile", @"text": @"A profile keeps its own sign-ins, cookies, history and tabs.", @"ok": @"Create", @"fields": @[@{@"name": @"name", @"placeholder": @"Name, e.g. Work"}]};
    [S addObject:SSection(@"profiles", @"Profiles", @"Separate sign-ins, cookies, history and tabs, one window per profile. Switch from the badge beside the address bar.", @"person", @[
        SGroup(@"Your profiles", profRows), SGroup(nil, @[ newProf ]) ])];

    // ── Bookmarks & Import
    NSMutableDictionary *helium = SButton(@"reimport", @"Helium", @"Replaces Flint's bookmarks with Helium's, including folders and icons.", @"Import…", ^(NSDictionary *a, void (^done)(NSString *)) {
        [NSFileManager.defaultManager removeItemAtPath:SupportFile(@"bookmarks.json") error:nil];
        [Defaults() removeObjectForKey:@"iconsImported"];
        [VBookmarks.shared performSelector:@selector(load)];
        [VFavicons.shared performSelector:@selector(importHelium)];
        for (VWindow *w in gWindows) [w.bookmarksBar reload];
        done([NSString stringWithFormat:@"Imported %lu bookmarks", (unsigned long)VBookmarks.shared.allURLs.count]);
    });
    helium[@"confirm"] = @{@"title": @"Import bookmarks from Helium?", @"text": @"Flint's current bookmarks will be replaced.", @"ok": @"Import"};
    [S addObject:SSection(@"bookmarks", @"Bookmarks & Import", @"Bring your bookmarks and site icons over from another browser.", @"bookmark", @[
        SGroup(@"Your bookmarks", @[ SValue(@"Saved bookmarks", nil, [NSString stringWithFormat:@"%lu", (unsigned long)VBookmarks.shared.allURLs.count]),
            SButton(@"bmManager", @"Bookmark manager", @"Edit, sort, import and export. ⌥⌘B", @"Open", ^(NSDictionary *a, void (^done)(NSString *)) { [win showBookmarks:nil]; done(nil); }) ]),
        SGroup(@"Import", @[ helium ]) ])];

    // ── Shortcuts
    NSMutableArray *sg = [NSMutableArray array];
    for (NSArray *g in @[
        @[@"Tabs", @[@[@"New tab", @"⌘T"], @[@"Close tab", @"⌘W"], @[@"Reopen closed tab", @"⇧⌘T"], @[@"Next / previous tab", @"⌃⇥  ⌃⇧⇥"], @[@"Go to tab 1–9", @"⌘1 … ⌘9"], @[@"Pin tab", @"⇧⌘P"], @[@"Duplicate tab", @"⇧⌘K"], @[@"Mute tab", @"⌃⌘M"], @[@"Split view", @"⌃⌘S"]]],
        @[@"Pages", @[@[@"Address bar", @"⌘L"], @[@"Reload / hard reload", @"⌘R  ⇧⌘R"], @[@"Back / forward", @"⌘[  ⌘]"], @[@"Find on page", @"⌘F  ⌘G  ⇧⌘G"], @[@"Zoom in / out / reset", @"⌘+  ⌘−  ⌘0"], @[@"Bookmark page", @"⌘D"], @[@"Save page", @"⇧⌘S"], @[@"View source", @"⌥⌘U"], @[@"Picture in Picture", @"⌃⌘P"], @[@"Reader", @"⌃⌘R"]]],
        @[@"Flint", @[@[@"Toggle sidebar", @"⌘S"], @[@"Toggle bookmarks bar", @"⇧⌘B"], @[@"History", @"⌘Y"], @[@"Bookmarks", @"⌥⌘B"], @[@"Downloads", @"⌥⌘L"], @[@"Settings", @"⌘,"], @[@"Full screen", @"⌃⌘F"], @[@"Clear browsing data", @"⇧⌘⌫"]]]]) {
        NSMutableArray *rows = [NSMutableArray array]; for (NSArray *r in g[1]) [rows addObject:SValue(r[0], nil, r[1])];
        [sg addObject:SGroup(g[0], rows)];
    }
    [S addObject:SSection(@"shortcuts", @"Shortcuts", @"The keyboard does almost everything in Flint.", @"command", sg)];

    // ── Advanced
    NSMutableDictionary *reset = SButton(@"resetSettings", @"Restore default settings", @"Your bookmarks, history, tabs and extensions are kept.", @"Reset…", ^(NSDictionary *a, void (^done)(NSString *)) {
        for (NSString *k in @[kTheme, kAccent, kDensity, kSidebarRight, kHideButtons, kShowExtra, kAddrWidth, kExtPinned, kHTTPSOnly, kGPC, kClearOnQuit, kSitePerms, kJSOff, kCustomEngine, kUserAgent,
                              kConfirmQuit, kMinFont, kSearch, kStartup, kBlock, kStrip, kCookieReject, kAutoPiP, kCodec, kCodec30, kBgThrottle, kSingleProcess, kRestorePaused, kResumeMedia, kLazyRestore, kSleepMins,
                              kShowBookmarks, kScripts, kAskDownload, kDefaultZoom, kZoom, kAllowlist, kHomeTopSites, kDLAccel, kDLConns, kDLActive, kDLLimit])
            [Defaults() removeObjectForKey:k];
        FlintApplyTheme(); FlintReloadBlocklists(); RelayoutAll();
        done(@"Settings restored");
    });
    reset[@"confirm"] = @{@"title": @"Restore default settings?", @"text": @"Theme, search engine, privacy, site and download choices go back to their defaults.", @"ok": @"Reset", @"danger": @YES};
    [S addObject:SSection(@"advanced", @"Advanced", @"For when a site needs convincing, or you're building one.", @"wrench", @[
        SGroup(@"Compatibility", @[ SSelect(@"ua", @"Identify Flint as", @"Some sites only work properly for certain browsers. Applies to pages you open next.", @[@"Safari (recommended)", @"Chrome", @"Firefox"], [Defaults() integerForKey:kUserAgent],
                                            ^(NSInteger i) { [Defaults() setInteger:i forKey:kUserAgent]; }) ]),
        SGroup(@"Developers", @[ SValue(@"Web Inspector", @"Right-click any page and choose Inspect Element.", @"On"),
            SButton(@"showLog", @"Debug log", @"Written to ~/Documents/Flint/flint.log while developing.", @"Show", ^(NSDictionary *a, void (^done)(NSString *)) {
                NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Flint/flint.log"];
                if ([NSFileManager.defaultManager fileExistsAtPath:p]) [NSWorkspace.sharedWorkspace selectFile:p inFileViewerRootedAtPath:@""];
                done(nil); }) ]),
        SGroup(@"Reset", @[ reset ]) ])];

    // ── About
    NSString *v = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.4";
    [S addObject:SSection(@"about", @"About Flint", nil, @"info", @[
        SGroup(nil, @[ SValue(@"Version", nil, v), SNote(@"Engine", @"WebKit, the engine inside Safari: fast, light on battery, and maintained by Apple."),
                       SNote(@"Extensions", @"Flint's own Chrome-compatible extension layer."), SNote(@"Window", @"Native AppKit, no web view for the interface."), SValue(@"Licence", nil, @"MIT") ]) ])];
    return S;
}

static void SettingsOp(NSString *op, NSDictionary *b, VWindow *win, void (^reply)(id, NSString *)) {
    NSString *ident = [b[@"id"] isKindOfClass:NSString.class] ? b[@"id"] : @"";
    if ([op isEqualToString:@"settings.schema"]) { reply(@{@"sections": SettingsSchema(win)}, nil); return; }
    if ([op isEqualToString:@"settings.set"]) {
        if (!gSSet) SettingsSchema(win);
        SSetter s = gSSet[ident];
        if (s) s(b[@"value"]);
        dispatch_async(dispatch_get_main_queue(), ^{ reply(@{@"sections": SettingsSchema(win)}, nil); });
        return;
    }
    if ([op isEqualToString:@"settings.action"]) {
        if (!gSAct) SettingsSchema(win);
        SAction a = gSAct[ident];
        if (!a) { reply(@{@"sections": SettingsSchema(win)}, nil); return; }
        NSDictionary *args = [b[@"args"] isKindOfClass:NSDictionary.class] ? b[@"args"] : @{};
        a(args, ^(NSString *toast) {
            if (toast.length) [win showToast:toast];
            reply(@{@"sections": SettingsSchema(win)}, nil);
        });
        return;
    }
    // cookies and website data, listed and removed from the page
    if ([op isEqualToString:@"settings.data"]) {
        WKWebsiteDataStore *ds = ProfileStore(gWin && !gWin.isPrivate ? gWin.profile : @"");
        [ds fetchDataRecordsOfTypes:WKWebsiteDataStore.allWebsiteDataTypes completionHandler:^(NSArray<WKWebsiteDataRecord *> *recs) {
            NSArray *remove = [b[@"remove"] isKindOfClass:NSArray.class] ? b[@"remove"] : nil;
            BOOL all = [b[@"all"] boolValue];
            if (remove || all) {
                NSMutableArray *gone = [NSMutableArray array];
                for (WKWebsiteDataRecord *r in recs) if (all || [remove containsObject:r.displayName]) [gone addObject:r];
                [ds removeDataOfTypes:WKWebsiteDataStore.allWebsiteDataTypes forDataRecords:gone completionHandler:^{ reply(@{@"removed": @(gone.count)}, nil); }];
                return;
            }
            NSMutableArray *names = [NSMutableArray array];
            for (WKWebsiteDataRecord *r in recs) [names addObject:r.displayName];
            reply(@{@"sites": [names sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]}, nil);
        }];
        return;
    }
    reply(nil, @"unknown");
}
