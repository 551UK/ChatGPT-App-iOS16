// Gecko-powered ChatGPT app for iOS 16.
// The website remains unmodified; only Reynard's native browser chrome is hidden.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <sqlite3.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>

static NSString *const CGBundleID = @"com.551uk.chatgptios16";
static NSString *const CGHomeURL = @"https://chatgpt.com/";
static NSString *const CGStartupTitleMarker = @"__CG_STARTING__";
static IMP CGOriginalControllerLoad = NULL;
static IMP CGOriginalControllerLayout = NULL;
static IMP CGOriginalControllerAppear = NULL;
static IMP CGOriginalUIViewSetHidden = NULL;
static IMP CGOriginalUIViewBounds = NULL;
static BOOL CGHooksInstalled = NO;
static const void *CGConstraintsAdjustedKey = &CGConstraintsAdjustedKey;
static const void *CGLayoutPendingKey = &CGLayoutPendingKey;
static const void *CGToolbarRelayoutKey = &CGToolbarRelayoutKey;
static const void *CGStartupOverlayKey = &CGStartupOverlayKey;

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
        const char *mark = "UPDATE tabs SET title=? WHERE id=?";
        if (sqlite3_prepare_v2(db, mark, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, CGStartupTitleMarker.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, chatID.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
        }
        sqlite3_finalize(stmt);

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

// Full-screen app navigation. Gecko remains the page engine and all Reynard
// browser chrome stays hidden. Navigation is gesture-only: swipe right from
// the left edge to trigger Gecko history back.

static NSString *CGTabStorePath(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (!dirs.count) return nil;
    return [dirs[0] stringByAppendingPathComponent:@"AppData/TabManagement/TabManagement"];
}

static BOOL CGStartupPageReady(void) {
    NSString *path = CGTabStorePath();
    if (!path.length) return NO;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NO;
    }
    sqlite3_busy_timeout(db, 150);

    BOOL ready = NO;
    sqlite3_stmt *stmt = NULL;
    const char *sql =
      "SELECT t.title, t.url FROM tab_state s "
      "JOIN tabs t ON t.id=s.selected_regular_tab_id "
      "WHERE s.id=1 LIMIT 1";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW) {
        const char *titleValue = (const char *)sqlite3_column_text(stmt, 0);
        const char *urlValue = (const char *)sqlite3_column_text(stmt, 1);
        NSString *title = titleValue ? [NSString stringWithUTF8String:titleValue] : @"";
        NSString *url = urlValue ? [NSString stringWithUTF8String:urlValue] : @"";
        NSString *lowerURL = url.lowercaseString;
        BOOL isChatGPT = [lowerURL hasPrefix:@"https://chatgpt.com"] ||
                         [lowerURL hasPrefix:@"https://www.chatgpt.com"] ||
                         [lowerURL hasPrefix:@"https://chat.openai.com"];
        ready = isChatGPT && title.length > 0 && ![title isEqualToString:CGStartupTitleMarker];
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return ready;
}

static UIImage *CGStartupIcon(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    for (NSString *name in @[@"AppIcon60x60@3x.png",
                              @"AppIcon60x60@2x.png",
                              @"AppIcon60x60.png"]) {
        NSString *path = [bundle.bundlePath stringByAppendingPathComponent:name];
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image) return image;
    }
    return nil;
}

@interface CGStartupOverlay : NSObject
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UIView *overlay;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) NSDate *startedAt;
@property(nonatomic,assign) BOOL finished;
- (void)installInController:(UIViewController *)controller;
@end

@implementation CGStartupOverlay

- (void)installInController:(UIViewController *)controller {
    if (self.overlay || !controller.isViewLoaded) return;
    self.owner = controller;
    self.startedAt = NSDate.date;

    UIView *root = controller.view;
    UIView *overlay = [[UIView alloc] initWithFrame:root.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.systemBackgroundColor;
    overlay.accessibilityIdentifier = @"ChatGPTNativeStartupLoader";

    UIImageView *icon = [[UIImageView alloc] initWithImage:CGStartupIcon()];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.layer.cornerRadius = 18.0;
    icon.clipsToBounds = YES;
    [overlay addSubview:icon];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"ChatGPT";
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    [overlay addSubview:label];

    UIActivityIndicatorView *spinner =
      [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = UIColor.secondaryLabelColor;
    [spinner startAnimating];
    [overlay addSubview:spinner];
    self.spinner = spinner;

    [root addSubview:overlay];
    self.overlay = overlay;

    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-42.0],
        [icon.widthAnchor constraintEqualToConstant:72.0],
        [icon.heightAnchor constraintEqualToConstant:72.0],

        [label.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:16.0],
        [label.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],

        [spinner.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:18.0],
        [spinner.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
    ]];

    NSLog(@"[ChatGPTGecko] Native startup loader shown");
    [self scheduleReadyCheck];
}

- (void)scheduleReadyCheck {
    if (self.finished) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL pageReady = CGStartupPageReady();
        dispatch_async(dispatch_get_main_queue(), ^{
            CGStartupOverlay *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.finished) return;

            NSTimeInterval elapsed = -[strongSelf.startedAt timeIntervalSinceNow];
            // Give the document-start cleanup a fraction of a second after the
            // Gecko title update so the loader never reveals the old web UI.
            if ((pageReady && elapsed >= 0.9) || elapsed >= 8.0) {
                [strongSelf finishAnimated:YES];
            } else {
                [strongSelf scheduleReadyCheck];
            }
        });
    });
}

- (void)finishAnimated:(BOOL)animated {
    if (self.finished) return;
    self.finished = YES;
    UIView *overlay = self.overlay;
    if (!overlay) return;

    [self.spinner stopAnimating];
    void (^cleanup)(void) = ^{
        [overlay removeFromSuperview];
        self.overlay = nil;
        NSLog(@"[ChatGPTGecko] Native startup loader hidden");
    };
    if (!animated) {
        cleanup();
        return;
    }
    [UIView animateWithDuration:0.24
                     animations:^{ overlay.alpha = 0.0; }
                     completion:^(__unused BOOL finished) { cleanup(); }];
}
@end

@interface CGAppNavigation : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UIScreenEdgePanGestureRecognizer *backGesture;
- (void)installInController:(UIViewController *)controller;
@end

@implementation CGAppNavigation

- (void)goBack {
    UIViewController *owner = self.owner;
    SEL action = NSSelectorFromString(@"goBackKeyCommand:");
    if (owner && [owner respondsToSelector:action]) {
        ((void (*)(id,SEL,id))objc_msgSend)(owner, action, nil);
    }
}

- (void)handleBackSwipe:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint translation = [gesture translationInView:gesture.view];
    CGPoint velocity = [gesture velocityInView:gesture.view];
    if (translation.x > 55.0 && velocity.x >= 0.0) {
        [self goBack];
    }
}

- (void)installInController:(UIViewController *)controller {
    if (self.backGesture) return;
    self.owner = controller;

    UIScreenEdgePanGestureRecognizer *gesture =
      [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self
                                                       action:@selector(handleBackSwipe:)];
    gesture.edges = UIRectEdgeLeft;
    gesture.cancelsTouchesInView = NO;
    gesture.delegate = self;
    [controller.view addGestureRecognizer:gesture];
    self.backGesture = gesture;

    NSLog(@"[ChatGPTGecko] Full-screen swipe-back navigation installed");
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
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
// tries to show it again. The replacement is scoped to Reynard subclasses.
static void CGAlwaysHideChrome(UIView *self, SEL cmd, BOOL requested) {
    if (CGOriginalUIViewSetHidden) {
        ((void (*)(id,SEL,BOOL))CGOriginalUIViewSetHidden)(self, cmd, CGIsOurApp() ? YES : requested);
    }
}

static CGRect CGBottomToolbarBounds(UIView *self, SEL cmd) {
    CGRect bounds = CGRectZero;
    if (CGOriginalUIViewBounds) {
        bounds = ((CGRect (*)(id,SEL))CGOriginalUIViewBounds)(self, cmd);
    }
    // BrowserChrome.bottomToolbarTransitionFrame() reads bottomToolbar.bounds
    // directly. Returning a zero height here guarantees ToolbarController sees
    // no hidden browser toolbar, even if Auto Layout later restores its frame.
    bounds.size.height = 0;
    return bounds;
}

static void CGInstallChromeSuppression(void) {
    static BOOL installed = NO;
    if (installed) return;

    Class browserChrome = NSClassFromString(@"Reynard.BrowserChrome");
    Class bottomToolbar = NSClassFromString(@"Reynard.BottomToolbar");
    Class overview = NSClassFromString(@"Reynard.TabOverview");
    if (!browserChrome || !bottomToolbar || !overview) return;

    Method hiddenMethod = class_getInstanceMethod(UIView.class, @selector(setHidden:));
    Method boundsMethod = class_getInstanceMethod(UIView.class, @selector(bounds));

    CGOriginalUIViewSetHidden = method_getImplementation(hiddenMethod);
    CGOriginalUIViewBounds = method_getImplementation(boundsMethod);

    // Keep Reynard's browser surfaces permanently hidden in this app.
    class_replaceMethod(browserChrome, @selector(setHidden:), (IMP)CGAlwaysHideChrome,
                        method_getTypeEncoding(hiddenMethod));
    class_replaceMethod(overview, @selector(setHidden:), (IMP)CGAlwaysHideChrome,
                        method_getTypeEncoding(hiddenMethod));

    // This is the actual viewport-gap fix: ToolbarController reads the hidden
    // BottomToolbar's bounds to calculate Gecko's dynamic-toolbar geometry.
    // Report zero height so no invisible browser strip is reserved.
    class_replaceMethod(bottomToolbar, @selector(bounds), (IMP)CGBottomToolbarBounds,
                        method_getTypeEncoding(boundsMethod));

    NSLog(@"[ChatGPTGecko] Chrome hidden; bottom toolbar viewport height forced to zero");
    installed = YES;
}

static void CGApplyAppLayout(UIViewController *controller) {
    if (!CGIsBrowserController(controller) || !controller.isViewLoaded) return;
    UIView *root = controller.view;
    UIView *content = nil;
    UIView *chrome = nil;
    UIView *overview = nil;

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

    CGAppNavigation *navigation = objc_getAssociatedObject(controller, CGAppNavigationKey);
    if (!navigation) {
        navigation = [CGAppNavigation new];
        objc_setAssociatedObject(controller, CGAppNavigationKey, navigation,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [navigation installInController:controller];
    }

    // Full-screen ChatGPT content with all Reynard browser chrome hidden.
    NSArray<NSLayoutConstraint *> *ours =
      objc_getAssociatedObject(content, CGConstraintsAdjustedKey);
    if (!ours) {
        content.translatesAutoresizingMaskIntoConstraints = NO;
        ours = @[
            [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [content.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor],
            [content.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]
        ];
        objc_setAssociatedObject(content, CGConstraintsAdjustedKey, ours,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (NSLayoutConstraint *constraint in root.constraints.copy) {
        if ((constraint.firstItem == content || constraint.secondItem == content) &&
            ![ours containsObject:constraint] && constraint.active) {
            constraint.active = NO;
        }
    }
    [NSLayoutConstraint activateConstraints:ours];

    chrome.hidden = YES;
    chrome.userInteractionEnabled = NO;
    if (overview) {
        overview.hidden = YES;
        overview.userInteractionEnabled = NO;
    }
    [root bringSubviewToFront:content];
    CGStartupOverlay *loader = objc_getAssociatedObject(controller, CGStartupOverlayKey);
    if (loader.overlay) [root bringSubviewToFront:loader.overlay];

    // Recalculate Gecko offsets once after the zero-height toolbar hook is active.
    if (![objc_getAssociatedObject(controller, CGToolbarRelayoutKey) boolValue]) {
        objc_setAssociatedObject(controller, CGToolbarRelayoutKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakRoot = root;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *strongRoot = weakRoot;
            [strongRoot setNeedsLayout];
            [strongRoot layoutIfNeeded];
        });
    }
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

static void CGControllerDidLoad(id controller, SEL cmd) {
    if (CGOriginalControllerLoad) ((void (*)(id,SEL))CGOriginalControllerLoad)(controller, cmd);
    if (!CGIsBrowserController(controller)) return;

    CGStartupOverlay *loader = objc_getAssociatedObject(controller, CGStartupOverlayKey);
    if (!loader) {
        loader = [CGStartupOverlay new];
        objc_setAssociatedObject(controller, CGStartupOverlayKey, loader,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [loader installInController:(UIViewController *)controller];
    }
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
    // This app has no browser toolbar. Disable Reynard's dynamic toolbar mode
    // so ToolbarController sends zero max/min/content bottom insets to Gecko.
    [prefs setBool:NO forKey:@"default.AppearanceSettings.scrollToHideToolbarEnabled"];
    // Other sites remain prompt-based; chatgpt.com itself is explicitly
    // pre-allowed in Reynard's SitePermissionStore database.
    [prefs setObject:@"ask_to_allow" forKey:@"default.SitePermissionSettings.defaultMicrophonePermission"];
    [prefs setObject:@"ask_to_allow" forKey:@"default.SitePermissionSettings.defaultCameraPermission"];
    [prefs synchronize];
}

static void CGInstallHooks(void) {
    if (!CGIsOurApp() || CGHooksInstalled) return;
    Method load = class_getInstanceMethod(UIViewController.class, @selector(viewDidLoad));
    Method layout = class_getInstanceMethod(UIViewController.class, @selector(viewDidLayoutSubviews));
    Method appear = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    if (!load || !layout || !appear) return;
    CGOriginalControllerLoad = method_getImplementation(load);
    CGOriginalControllerLayout = method_getImplementation(layout);
    CGOriginalControllerAppear = method_getImplementation(appear);
    method_setImplementation(load, (IMP)CGControllerDidLoad);
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
