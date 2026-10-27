// Gecko-powered ChatGPT app for iOS 16.
// The website remains unmodified; only Reynard's native browser chrome is hidden.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <sqlite3.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

static NSString *const CGBundleID = @"com.551uk.chatgptios16";
static NSString *const CGHomeURL = @"https://chatgpt.com/";
static IMP CGOriginalControllerLayout = NULL;
static IMP CGOriginalControllerAppear = NULL;
static IMP CGOriginalUIViewSetHidden = NULL;
static BOOL CGHooksInstalled = NO;
static const void *CGConstraintsAdjustedKey = &CGConstraintsAdjustedKey;
static const void *CGLayoutPendingKey = &CGLayoutPendingKey;

typedef void (*CGBridgeViewFunction)(void *);
static void *CGBridgeHandle = NULL;
static CGBridgeViewFunction CGFixViewportFunction = NULL;
static CGBridgeViewFunction CGLoadHomeFunction = NULL;
static CGBridgeViewFunction CGGoBackFunction = NULL;

static void CGLoadBridge(void) {
    if (CGBridgeHandle) return;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"ChatGPTBridge"
                                                    ofType:@"dylib"
                                               inDirectory:@"Frameworks"];
    if (!path.length) {
        NSLog(@"[ChatGPTGecko] Missing ChatGPTBridge.dylib");
        return;
    }
    CGBridgeHandle = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!CGBridgeHandle) {
        NSLog(@"[ChatGPTGecko] Bridge load failed: %s", dlerror());
        return;
    }
    CGFixViewportFunction = (CGBridgeViewFunction)dlsym(CGBridgeHandle, "CGFixGeckoViewport");
    CGLoadHomeFunction = (CGBridgeViewFunction)dlsym(CGBridgeHandle, "CGLoadChatGPTHome");
    CGGoBackFunction = (CGBridgeViewFunction)dlsym(CGBridgeHandle, "CGGoBackInGecko");
}

static void CGFixGeckoViewport(UIView *root) {
    CGLoadBridge();
    if (CGFixViewportFunction) CGFixViewportFunction((__bridge void *)root);
}

static void CGLoadChatGPTHome(UIView *root) {
    CGLoadBridge();
    if (CGLoadHomeFunction) CGLoadHomeFunction((__bridge void *)root);
}

static BOOL CGGoBackInGecko(UIView *root) {
    CGLoadBridge();
    if (!CGGoBackFunction) return NO;
    CGGoBackFunction((__bridge void *)root);
    return YES;
}

static BOOL CGIsOurApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:CGBundleID];
}

static void CGPreallowChatGPTMicrophoneSite(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (!dirs.count) return;
    NSString *dir = [dirs[0] stringByAppendingPathComponent:@"AppData/SitePermissions"];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:&error]) {
        NSLog(@"[ChatGPTGecko] Site permission directory failed: %@", error);
        return;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"SitePermissions"];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 2500);
    const char *schema =
      "CREATE TABLE IF NOT EXISTS site_permissions ("
      "host TEXT NOT NULL, permission_key TEXT NOT NULL, action TEXT NOT NULL, "
      "updated_at REAL NOT NULL, PRIMARY KEY(host, permission_key));"
      "CREATE INDEX IF NOT EXISTS idx_site_permissions_permission_key "
      "ON site_permissions(permission_key);"
      "CREATE INDEX IF NOT EXISTS idx_site_permissions_updated_at "
      "ON site_permissions(updated_at);";
    sqlite3_exec(db, schema, NULL, NULL, NULL);
    sqlite3_stmt *stmt = NULL;
    const char *upsert =
      "INSERT INTO site_permissions(host,permission_key,action,updated_at) "
      "VALUES('chatgpt.com','microphone','allowed',?) "
      "ON CONFLICT(host,permission_key) DO UPDATE SET action='allowed', updated_at=excluded.updated_at";
    if (sqlite3_prepare_v2(db, upsert, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_double(stmt, 1, NSDate.date.timeIntervalSince1970);
        sqlite3_step(stmt);
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    NSLog(@"[ChatGPTGecko] chatgpt.com microphone site permission=allowed");
}

static void CGRequestIOSMicrophoneIfNeeded(void) {
    AVAuthorizationStatus status =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status != AVAuthorizationStatusNotDetermined) {
        NSLog(@"[ChatGPTGecko] iOS microphone state=%ld", (long)status);
        return;
    }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                            completionHandler:^(BOOL granted) {
        NSLog(@"[ChatGPTGecko] iOS microphone prompt result=%d", granted);
    }];
}

static void CGArmIOSMicrophonePrompt(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
          addObserverForName:UIApplicationDidBecomeActiveNotification
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(__unused NSNotification *note) {
            CGRequestIOSMicrophoneIfNeeded();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                CGRequestIOSMicrophoneIfNeeded();
            }
        });
    });
}


// Reynard v0.19.0 creates an about:blank tab on first launch when
// openingScreen == lastTab, and the customNewTabURL does NOT navigate it.
// Since the app intentionally hides Reynard's address bar, an empty tab
// otherwise appears as an unfixable white/black screen. Seed a real Gecko
// tab before Reynard's TabManagementStore singleton is instantiated.
// Do not reset the Gecko profile, site cookies or existing conversations.
static void CGEnsureStartupTab(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (!dirs.count) return;
    NSString *dir = [dirs[0] stringByAppendingPathComponent:@"AppData/TabManagement"];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:&error]) {
        NSLog(@"[ChatGPTGecko] Failed to create tab directory: %@", error);
        return;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"TabManagement"];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSLog(@"[ChatGPTGecko] Could not open tab store");
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 2500);
    const char *schema =
        "CREATE TABLE IF NOT EXISTS tab_state ("
        "id INTEGER PRIMARY KEY CHECK(id = 1), selected_regular_tab_id TEXT,"
        "selected_private_tab_id TEXT, selected_tab_mode TEXT NOT NULL,"
        "last_tab_overview TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS tabs ("
        "id TEXT PRIMARY KEY, title TEXT NOT NULL, url TEXT, created_at REAL,"
        "opened_from TEXT, tab_session_state TEXT,"
        "is_muted INTEGER NOT NULL DEFAULT 0,"
        "is_private INTEGER NOT NULL, position INTEGER NOT NULL);"
        "CREATE INDEX IF NOT EXISTS idx_tabs_private_position ON tabs(is_private, position ASC);";
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK ||
        sqlite3_exec(db, schema, NULL, NULL, NULL) != SQLITE_OK) {
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        NSLog(@"[ChatGPTGecko] Could not initialize tab store: %s", sqlite3_errmsg(db));
        sqlite3_close(db);
        return;
    }

    // Prefer an existing ChatGPT conversation tab; don't make new tabs on
    // every launch. Repair earlier builds that persisted only an empty tab.
    NSString *chatID = nil;
    sqlite3_stmt *stmt = NULL;
    const char *lookup = "SELECT id FROM tabs WHERE is_private = 0 AND "
                         "(url LIKE 'https://chatgpt.com/%' OR url = 'https://chatgpt.com') "
                         "ORDER BY position DESC LIMIT 1";
    if (sqlite3_prepare_v2(db, lookup, -1, &stmt, NULL) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW) {
        const char *value = (const char *)sqlite3_column_text(stmt, 0);
        if (value) chatID = [NSString stringWithUTF8String:value];
    }
    sqlite3_finalize(stmt);
    if (!chatID.length) {
        chatID = NSUUID.UUID.UUIDString;
        int position = 0;
        if (sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(position), -1) + 1 FROM tabs WHERE is_private=0", -1, &stmt, NULL) == SQLITE_OK &&
            sqlite3_step(stmt) == SQLITE_ROW) position = sqlite3_column_int(stmt, 0);
        sqlite3_finalize(stmt);
        stmt = NULL;
        const char *insert = "INSERT INTO tabs "
          "(id,title,url,created_at,opened_from,tab_session_state,is_muted,is_private,position) "
          "VALUES (?, 'ChatGPT', ?, ?, NULL, NULL, 0, 0, ?)";
        if (sqlite3_prepare_v2(db, insert, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, chatID.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, CGHomeURL.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_double(stmt, 3, NSDate.date.timeIntervalSince1970);
            sqlite3_bind_int(stmt, 4, position);
            if (sqlite3_step(stmt) != SQLITE_DONE) chatID = nil;
        } else chatID = nil;
        sqlite3_finalize(stmt);
    }
    if (chatID.length) {
        stmt = NULL;
        const char *select = "INSERT INTO tab_state (id, selected_regular_tab_id, selected_private_tab_id, selected_tab_mode, last_tab_overview) "
                             "VALUES (1, ?, NULL, 'regular', 'regular') "
                             "ON CONFLICT(id) DO UPDATE SET selected_regular_tab_id=excluded.selected_regular_tab_id, "
                             "selected_tab_mode='regular', last_tab_overview='regular'";
        if (sqlite3_prepare_v2(db, select, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, chatID.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_DONE) NSLog(@"[ChatGPTGecko] Tab selection failed");
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_exec(db, chatID.length ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL);
    sqlite3_close(db);
    NSLog(@"[ChatGPTGecko] Startup tab prepared: %@", chatID ?: @"failure");
}

static NSString *CGSelectedTabURL(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (!dirs.count) return nil;
    NSString *path = [dirs[0] stringByAppendingPathComponent:@"AppData/TabManagement/TabManagement"];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_busy_timeout(db, 150);
    sqlite3_stmt *stmt = NULL;
    NSString *url = nil;
    const char *sql =
      "SELECT t.url FROM tab_state s "
      "LEFT JOIN tabs t ON t.id=s.selected_regular_tab_id "
      "WHERE s.id=1 LIMIT 1";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW) {
        const char *v = (const char *)sqlite3_column_text(stmt, 0);
        if (v) url = [NSString stringWithUTF8String:v];
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return url;
}

static BOOL CGIsVoiceURL(NSString *url) {
    if (!url.length) return NO;
    NSString *lower = url.lowercaseString;
    return [lower containsString:@"/voice"] ||
           [lower containsString:@"voice-mode"] ||
           [lower containsString:@"realtime"];
}

// The normal ChatGPT website header/sidebar remain the primary navigation so
// all current web features keep working. Native UI is used only as a recovery
// control on voice routes, matching the official app's back affordance.
@interface CGAppNavigation : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UIButton *voiceBackButton;
@property(nonatomic,strong) UIButton *newChatButton;
@property(nonatomic,strong) UIScreenEdgePanGestureRecognizer *voiceBackGesture;
- (void)installInController:(UIViewController *)controller;
- (void)updateLayout;
@end

@implementation CGAppNavigation

- (void)returnFromVoice {
    UIViewController *owner = self.owner;
    if (!owner) return;
    if (!CGGoBackInGecko(owner.view)) {
        SEL back = NSSelectorFromString(@"goBackKeyCommand:");
        if ([owner respondsToSelector:back]) {
            ((void (*)(id,SEL,id))objc_msgSend)(owner, back, nil);
        }
    }
    __weak UIViewController *weakOwner = owner;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *strongOwner = weakOwner;
        if (!strongOwner || !CGIsVoiceURL(CGSelectedTabURL())) return;
        SEL newTab = NSSelectorFromString(@"newTabKeyCommand:");
        if ([strongOwner respondsToSelector:newTab]) {
            ((void (*)(id,SEL,id))objc_msgSend)(strongOwner, newTab, nil);
        }
    });
}


- (void)newChat {
    UIViewController *owner = self.owner;
    if (!owner) return;
    CGLoadChatGPTHome(owner.view);
}

- (void)voiceBackSwipe:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (!CGIsVoiceURL(CGSelectedTabURL())) return;
    if (gesture.state == UIGestureRecognizerStateEnded &&
        [gesture translationInView:gesture.view].x > 70) {
        [self returnFromVoice];
    }
}

- (void)installInController:(UIViewController *)controller {
    if (self.voiceBackGesture) return;
    self.owner = controller;

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    [back setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];
    back.tintColor = UIColor.labelColor;
    back.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.96];
    back.layer.cornerRadius = 19;
    back.layer.borderWidth = 0.5;
    back.layer.borderColor = UIColor.separatorColor.CGColor;
    back.accessibilityLabel = @"Back to ChatGPT";
    back.accessibilityIdentifier = @"ChatGPTVoiceBack";
    [back addTarget:self action:@selector(returnFromVoice) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:back];
    self.voiceBackButton = back;

    UIButton *compose = [UIButton buttonWithType:UIButtonTypeSystem];
    [compose setImage:[UIImage systemImageNamed:@"square.and.pencil"] forState:UIControlStateNormal];
    compose.tintColor = UIColor.labelColor;
    compose.backgroundColor = UIColor.clearColor;
    compose.accessibilityLabel = @"New chat";
    compose.accessibilityIdentifier = @"ChatGPTNewChat";
    [compose addTarget:self action:@selector(newChat) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:compose];
    self.newChatButton = compose;

    UIScreenEdgePanGestureRecognizer *gesture =
      [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(voiceBackSwipe:)];
    gesture.edges = UIRectEdgeLeft;
    gesture.cancelsTouchesInView = NO;
    gesture.delegate = self;
    [controller.view addGestureRecognizer:gesture];
    self.voiceBackGesture = gesture;
    [self updateLayout];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)updateLayout {
    UIViewController *owner = self.owner;
    if (!owner.isViewLoaded || !self.voiceBackButton || !self.newChatButton) return;
    CGFloat width = CGRectGetWidth(owner.view.bounds);
    CGFloat y = owner.view.safeAreaInsets.top + 8;

    // Official-app-style compose control, positioned just left of the site's
    // login/account area so the web authentication button remains usable.
    self.newChatButton.frame = CGRectMake(MAX(180, width - 108), y, 38, 38);
    self.newChatButton.hidden = NO;
    self.newChatButton.userInteractionEnabled = YES;

    BOOL voiceVisible = CGIsVoiceURL(CGSelectedTabURL());
    self.voiceBackButton.hidden = !voiceVisible;
    self.voiceBackButton.userInteractionEnabled = voiceVisible;
    self.voiceBackButton.frame = CGRectMake(12, y, 38, 38);

    [owner.view bringSubviewToFront:self.newChatButton];
    if (voiceVisible) [owner.view bringSubviewToFront:self.voiceBackButton];
}
@end

static const void *CGAppNavigationKey = &CGAppNavigationKey;

// The Swift controller's own viewDidLayoutSubviews may not be reachable when
// the dylib constructor first runs. Hook UIViewController's *super* callbacks
// instead: the upstream BrowserViewController explicitly calls super from its
// appearance and layout methods. This also covers late-loaded Swift classes.
static BOOL CGIsBrowserController(id controller) {
    if (!CGIsOurApp() || ![controller isKindOfClass:UIViewController.class]) return NO;
    NSString *name = NSStringFromClass([controller class]);
    return [name isEqualToString:@"Reynard.BrowserViewController"] ||
           [name hasSuffix:@".BrowserViewController"] ||
           [name isEqualToString:@"_TtC7Reynard21BrowserViewController"];
}

// Keep browser navigation UI suppressed even when Reynard's Swift layout
// updates set .isHidden=false later. class_addMethod prevents accidentally
// replacing UIView's inherited implementation for every view in the process.
static void CGAlwaysHideChrome(UIView *self, SEL cmd, BOOL requested) {
    if (CGOriginalUIViewSetHidden) {
        ((void (*)(id,SEL,BOOL))CGOriginalUIViewSetHidden)(self, cmd, CGIsOurApp() ? YES : requested);
    }
}
static void CGInstallChromeSuppression(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class browserChrome = NSClassFromString(@"Reynard.BrowserChrome");
    Class overview = NSClassFromString(@"Reynard.TabOverview");
    if (!browserChrome || !overview) return;
    CGOriginalUIViewSetHidden = method_getImplementation(class_getInstanceMethod(UIView.class, @selector(setHidden:)));
    BOOL a = class_addMethod(browserChrome, @selector(setHidden:), (IMP)CGAlwaysHideChrome, "v@:B");
    BOOL b = class_addMethod(overview, @selector(setHidden:), (IMP)CGAlwaysHideChrome, "v@:B");
    // If upstream adds its own setHidden: override, don't override unknown
    // functionality; our appearance/layout enforcement still handles it.
    NSLog(@"[ChatGPTGecko] Chrome hooks: chrome=%d tabs=%d", a, b);
    installed = YES;
}

static void CGApplyAppLayout(UIViewController *controller) {
    if (!CGIsBrowserController(controller) || !controller.isViewLoaded) return;
    UIView *root = controller.view;
    UIView *content = nil;
    UIView *chrome = nil;
    UIView *overview = nil;
    // Upstream configureBrowserInterface() adds these three direct children.
    // Use direct subviews rather than recursively matching an unrelated
    // ChromeOverlayContentView before locating the real Gecko content.
    for (UIView *candidate in root.subviews) {
        NSString *type = NSStringFromClass(candidate.class);
        if ([type hasSuffix:@".ContentView"]) content = candidate;
        else if ([type hasSuffix:@".BrowserChrome"]) chrome = candidate;
        else if ([type hasSuffix:@".TabOverview"]) overview = candidate;
    }
    if (!content || !chrome) {
        NSLog(@"[ChatGPTGecko] Missing native views content=%d chrome=%d", !!content, !!chrome);
        return;
    }

    // Keep Gecko's own inner Auto Layout and keyboard constraints intact.
    // Only replace the ContentView's root placement, which Reynard otherwise
    // anchors to its bottom toolbar even if that toolbar is hidden.
    NSArray<NSLayoutConstraint *> *ours = objc_getAssociatedObject(content, CGConstraintsAdjustedKey);
    if (!ours) {
        content.translatesAutoresizingMaskIntoConstraints = NO;
        ours = @[
            [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [content.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor],
            [content.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor]
        ];
        objc_setAssociatedObject(content, CGConstraintsAdjustedKey, ours, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Reynard reapplies its native ContentView top/bottom anchors whenever
    // address-bar mode changes. Retire those root-level constraints each pass,
    // leaving our four safe-area constraints and every Gecko child untouched.
    for (NSLayoutConstraint *constraint in root.constraints.copy) {
        if ((constraint.firstItem == content || constraint.secondItem == content) &&
            ![ours containsObject:constraint] && constraint.active) {
            constraint.active = NO;
        }
    }
    [NSLayoutConstraint activateConstraints:ours];

    // Hide both native top URL and bottom toolbar as one BrowserChrome view.
    // Do not remove them: Reynard's layout methods still reference anchors.
    chrome.hidden = YES;
    chrome.userInteractionEnabled = NO;
    if (overview) {
        overview.hidden = YES;
        overview.userInteractionEnabled = NO;
    }
    [root bringSubviewToFront:content];
    CGFixGeckoViewport(root);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CGFixGeckoViewport(root);
    });
    CGAppNavigation *navigation = objc_getAssociatedObject(controller, CGAppNavigationKey);
    if (!navigation) {
        navigation = [CGAppNavigation new];
        objc_setAssociatedObject(controller, CGAppNavigationKey, navigation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [navigation installInController:controller];
        NSLog(@"[ChatGPTGecko] App-style voice navigation attached");
    }
    [navigation updateLayout];
}

// Schedule after the upstream override finishes laying out browser chrome.
static void CGScheduleAppLayout(UIViewController *controller) {
    if (!CGIsBrowserController(controller)) return;
    if ([objc_getAssociatedObject(controller, CGLayoutPendingKey) boolValue]) return;
    objc_setAssociatedObject(controller, CGLayoutPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        objc_setAssociatedObject(strongController, CGLayoutPendingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGInstallChromeSuppression();
        CGApplyAppLayout(strongController);
    });
}

static void CGControllerDidLayout(id controller, SEL cmd) {
    if (CGOriginalControllerLayout) ((void (*)(id,SEL))CGOriginalControllerLayout)(controller, cmd);
    CGScheduleAppLayout(controller);
}

static void CGControllerDidAppear(id controller, SEL cmd, BOOL animated) {
    if (CGOriginalControllerAppear) ((void (*)(id,SEL,BOOL))CGOriginalControllerAppear)(controller, cmd, animated);
    CGInstallChromeSuppression();
    CGScheduleAppLayout(controller);
}

static void CGConfigurePreferences(void) {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    [prefs setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [prefs setObject:CGHomeURL forKey:@"default.NewTabSettings.customNewTabURL"];
    [prefs setObject:@"lastTab" forKey:@"default.HomepageSettings.openingScreen"];
    [prefs setBool:NO forKey:@"default.HomepageSettings.showsRecommendations"];
    [prefs setBool:NO forKey:@"default.HomepageSettings.showsNewUpdates"];
    [prefs setBool:NO forKey:@"default.HomepageSettings.showsFavorites"];
    [prefs setBool:NO forKey:@"default.HomepageSettings.showsFrequentlyVisited"];
    // Other sites remain prompt-based; chatgpt.com itself is explicitly
    // pre-allowed in Reynard's SitePermissionStore database.
    [prefs setObject:@"ask_to_allow" forKey:@"default.SitePermissionSettings.defaultMicrophonePermission"];
    [prefs setObject:@"ask_to_allow" forKey:@"default.SitePermissionSettings.defaultCameraPermission"];
    [prefs synchronize];
}

static void CGInstallHooks(void) {
    if (!CGIsOurApp() || CGHooksInstalled) return;
    Method layout = class_getInstanceMethod(UIViewController.class, @selector(viewDidLayoutSubviews));
    Method appear = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    if (!layout || !appear) return;
    CGOriginalControllerLayout = method_getImplementation(layout);
    CGOriginalControllerAppear = method_getImplementation(appear);
    method_setImplementation(layout, (IMP)CGControllerDidLayout);
    method_setImplementation(appear, (IMP)CGControllerDidAppear);
    CGHooksInstalled = YES;
    NSLog(@"[ChatGPTGecko] Global controller super-hooks installed");
}

__attribute__((constructor))
static void CGStart(void) {
    @autoreleasepool {
        if (!CGIsOurApp()) return;
        CGConfigurePreferences();
        CGPreallowChatGPTMicrophoneSite();
        CGEnsureStartupTab();
        CGInstallHooks();
        CGArmIOSMicrophonePrompt();
        dispatch_async(dispatch_get_main_queue(), ^{ CGInstallChromeSuppression(); });
    }
}
