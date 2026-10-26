// Gecko-powered ChatGPT app for iOS 16.
// The website remains unmodified; only Reynard's native browser chrome is hidden.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <sqlite3.h>

static NSString *const CGBundleID = @"com.551uk.chatgptgecko";
static NSString *const CGHomeURL = @"https://chatgpt.com/";
static IMP CGOriginalLayout = NULL;
static BOOL CGHookInstalled = NO;
static NSInteger CGInstallAttempts = 0;
static const void *CGConstraintsAdjustedKey = &CGConstraintsAdjustedKey;

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

static void CGApplyAppLayout(UIViewController *controller) {
    if (!controller.isViewLoaded) return;
    UIView *root = controller.view;
    UIView *content = CGFindNamedView(root, @"ContentView");
    UIView *chrome = CGFindNamedView(root, @"BrowserChrome");
    UIView *overview = CGFindNamedView(root, @"TabOverview");
    if (!content || content == root || !chrome) return;

    // Do not force frames/translatesAutoresizingMaskIntoConstraints on a Swift
    // ContentView: Reynard controls its Gecko view using Auto Layout. Changing
    // that view to manual-frame mode can prevent Gecko from ever painting.
    // Replace only root-level chrome-dependent constraints with safe-area
    // constraints; leave every descendant Gecko constraint untouched.
    if (![objc_getAssociatedObject(content, CGConstraintsAdjustedKey) boolValue]) {
        for (NSLayoutConstraint *constraint in root.constraints.copy) {
            if (constraint.firstItem == content || constraint.secondItem == content) {
                constraint.active = NO;
            }
        }
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [content.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor],
            [content.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor]
        ]];
        objc_setAssociatedObject(content, CGConstraintsAdjustedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    chrome.hidden = YES;
    chrome.userInteractionEnabled = NO;
    if (overview) {
        overview.hidden = YES;
        overview.userInteractionEnabled = NO;
    }
    [root bringSubviewToFront:content];
}

static void CGBrowserDidLayout(id self, SEL _cmd) {
    if (CGOriginalLayout) ((void (*)(id, SEL))CGOriginalLayout)(self, _cmd);
    CGApplyAppLayout((UIViewController *)self);
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

static void CGInstallHook(void) {
    if (!CGIsOurApp() || CGHookInstalled) return;
    Class cls = NSClassFromString(@"Reynard.BrowserViewController");
    if (!cls) cls = objc_getClass("_TtC7Reynard21BrowserViewController");
    Method method = cls ? class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews)) : NULL;
    if (method) {
        CGOriginalLayout = method_getImplementation(method);
        if (CGOriginalLayout != (IMP)CGBrowserDidLayout)
            method_setImplementation(method, (IMP)CGBrowserDidLayout);
        CGHookInstalled = YES;
        NSLog(@"[ChatGPTGecko] Browser chrome suppression installed");
        return;
    }
    if (++CGInstallAttempts < 40)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ CGInstallHook(); });
}

__attribute__((constructor))
static void CGStart(void) {
    @autoreleasepool {
        if (!CGIsOurApp()) return;
        CGConfigurePreferences();
        CGEnsureStartupTab();
        dispatch_async(dispatch_get_main_queue(), ^{ CGInstallHook(); });
    }
}
