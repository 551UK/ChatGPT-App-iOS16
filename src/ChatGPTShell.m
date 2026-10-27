// Gecko-powered ChatGPT app for iOS 16.
// The website remains unmodified; only Reynard's native browser chrome is hidden.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <sqlite3.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static NSString *const CGBundleID = @"com.551uk.chatgptgecko";
static NSString *const CGHomeURL = @"https://chatgpt.com/";
static IMP CGOriginalControllerLayout = NULL;
static IMP CGOriginalControllerAppear = NULL;
static IMP CGOriginalUIViewSetHidden = NULL;
static BOOL CGHooksInstalled = NO;
static const void *CGConstraintsAdjustedKey = &CGConstraintsAdjustedKey;
static const void *CGLayoutPendingKey = &CGLayoutPendingKey;

static BOOL CGIsOurApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:CGBundleID];
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

static UIView *CGFindNamedView(UIView *root, NSString *fragment) {
    if (!root) return nil;
    NSString *name = NSStringFromClass([root class]);
    if ([name rangeOfString:fragment options:NSCaseInsensitiveSearch].location != NSNotFound)
        return root;
    for (UIView *child in root.subviews) {
        UIView *found = CGFindNamedView(child, fragment);
        if (found) return found;
    }
    return nil;
}

// Small native recovery menu: the website's fullscreen voice route can hide
// all browser navigation. The menu works independently of Gecko's web page,
// while keeping URL bars/tabs permanently hidden.
@interface CGAppActions : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UIScreenEdgePanGestureRecognizer *backGesture;
- (void)installInController:(UIViewController *)controller;
- (void)updateLayout;
@end

@implementation CGAppActions

- (void)returnToChats {
    UIViewController *owner = self.owner;
    // In Reynard 0.19.0 this @objc key command creates a new Gecko tab,
    // loads our configured https://chatgpt.com/ URL and deactivates the
    // current voice session. Avoid relying on the website's history state.
    SEL newTab = NSSelectorFromString(@"newTabKeyCommand:");
    if ([owner respondsToSelector:newTab]) {
        ((void (*)(id,SEL,id))objc_msgSend)(owner, newTab, nil);
    } else {
        NSLog(@"[ChatGPTGecko] newTabKeyCommand unavailable");
    }
}

- (void)requestMicrophone {
    AVAuthorizationStatus state = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (state == AVAuthorizationStatusNotDetermined) {
        __weak typeof(self) weakSelf = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showMicrophoneResult:granted];
            });
        }];
    } else {
        [self showMicrophoneResult:(state == AVAuthorizationStatusAuthorized)];
    }
}

- (void)showMicrophoneResult:(BOOL)allowed {
    UIViewController *owner = self.owner;
    if (!owner || owner.presentedViewController) return;
    NSString *message = allowed
      ? @"Microphone access is enabled for this app. Return to ChatGPT voice and tap ‘Tap to talk’. You may also need to allow ChatGPT's website-level permission."
      : @"iOS has blocked this app's microphone. Open Settings, choose ChatGPT, and enable Microphone, then retry.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(allowed ? @"Microphone enabled" : @"Microphone access needed")
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    if (!allowed) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Open Settings" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }]];
    }
    [owner presentViewController:alert animated:YES completion:nil];
}

- (void)refreshPage {
    SEL refresh = NSSelectorFromString(@"reloadPageKeyCommand:");
    if ([self.owner respondsToSelector:refresh])
        ((void (*)(id,SEL,id))objc_msgSend)(self.owner, refresh, nil);
}

- (void)backSwipe:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded &&
        [gesture translationInView:gesture.view].x > 75) {
        [self returnToChats];
    }
}

- (void)showActions {
    UIViewController *owner = self.owner;
    if (!owner || owner.presentedViewController) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"ChatGPT"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Back to chats" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self returnToChats];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"New chat" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self returnToChats];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Enable microphone" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self requestMicrophone];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Reload ChatGPT" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self refreshPage];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) { popover.sourceView = self.button; popover.sourceRect = self.button.bounds; }
    [owner presentViewController:sheet animated:YES completion:nil];
}

- (void)installInController:(UIViewController *)controller {
    if (self.button) return;
    self.owner = controller;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
    button.tintColor = UIColor.labelColor;
    button.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.94];
    button.layer.cornerRadius = 17;
    button.layer.borderWidth = 0.5;
    button.layer.borderColor = UIColor.separatorColor.CGColor;
    button.accessibilityLabel = @"ChatGPT options, back to chats and microphone access";
    button.accessibilityIdentifier = @"ChatGPTAppOptions";
    [button addTarget:self action:@selector(showActions) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:button];
    self.button = button;
    UIScreenEdgePanGestureRecognizer *back = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(backSwipe:)];
    back.edges = UIRectEdgeLeft;
    back.cancelsTouchesInView = NO;
    back.delegate = self;
    [controller.view addGestureRecognizer:back];
    self.backGesture = back;
    [self updateLayout];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)updateLayout {
    UIViewController *owner = self.owner;
    if (!owner.isViewLoaded || !self.button) return;
    // Below ChatGPT's mobile web header to avoid covering its sidebar and
    // compose controls. The rest of the view is the real site.
    CGFloat width = CGRectGetWidth(owner.view.bounds);
    CGFloat height = CGRectGetHeight(owner.view.bounds);
    CGFloat y = owner.view.safeAreaInsets.top + 48;
    self.button.frame = CGRectMake(MAX(8, width - 43), MIN(y, height - 43), 34, 34);
    [owner.view bringSubviewToFront:self.button];
}
@end

static const void *CGAppActionsKey = &CGAppActionsKey;

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
    CGAppActions *actions = objc_getAssociatedObject(controller, CGAppActionsKey);
    if (!actions) {
        actions = [CGAppActions new];
        objc_setAssociatedObject(controller, CGAppActionsKey, actions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [actions installInController:controller];
        NSLog(@"[ChatGPTGecko] Native website shell attached");
    }
    [actions updateLayout];
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
        CGEnsureStartupTab();
        CGInstallHooks();
        dispatch_async(dispatch_get_main_queue(), ^{ CGInstallChromeSuppression(); });
    }
}
