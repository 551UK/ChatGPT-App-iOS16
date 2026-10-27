// External web-link handoff for the dedicated ChatGPT app.
// Reynard already asks UIApplication to open user-initiated cross-site links,
// but it uses UIApplicationOpenURLOptionUniversalLinksOnly. That only succeeds
// for installed universal-link apps and otherwise leaves the URL in Gecko.
//
// This isolated module changes only those ChatGPT-originated HTTP(S) handoffs
// into a normal UIApplication open, so iOS sends them to the user's configured
// default browser. ChatGPT and authentication navigation stays inside the app.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>

static NSString *const CGExternalLinksBundleID = @"com.551uk.chatgptios16";

typedef void (*CGUIApplicationOpenURLIMP)(UIApplication *,
                                         SEL,
                                         NSURL *,
                                         NSDictionary *,
                                         void (^)(BOOL));

static CGUIApplicationOpenURLIMP CGOriginalUIApplicationOpenURL = NULL;

static BOOL CGExternalLinksIsOurApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:CGExternalLinksBundleID];
}

static NSString *CGExternalLinksTabStorePath(void) {
    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                            NSUserDomainMask,
                                            YES);
    if (!dirs.count) return nil;
    return [dirs[0] stringByAppendingPathComponent:@"AppData/TabManagement/TabManagement"];
}

static NSURL *CGExternalLinksCurrentSelectedURL(void) {
    NSString *path = CGExternalLinksTabStorePath();
    if (!path.length) return nil;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String,
                        &db,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                        NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return nil;
    }

    sqlite3_busy_timeout(db, 100);

    const char *sql =
        "SELECT t.url "
        "FROM tab_state s "
        "JOIN tabs t ON t.id = CASE "
        "  WHEN s.selected_tab_mode='private' THEN s.selected_private_tab_id "
        "  ELSE s.selected_regular_tab_id "
        "END "
        "WHERE s.id=1 LIMIT 1";

    NSURL *result = nil;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW) {
        const char *value = (const char *)sqlite3_column_text(stmt, 0);
        if (value) {
            NSString *string = [NSString stringWithUTF8String:value];
            result = [NSURL URLWithString:string];
        }
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return result;
}

static BOOL CGExternalLinksHostMatches(NSString *host, NSString *baseHost) {
    if (!host.length || !baseHost.length) return NO;

    NSString *h = host.lowercaseString;
    NSString *b = baseHost.lowercaseString;
    if ([h isEqualToString:b]) return YES;

    NSString *suffix = [@"." stringByAppendingString:b];
    return [h hasSuffix:suffix];
}

static BOOL CGExternalLinksIsChatGPTHost(NSString *host) {
    if (CGExternalLinksHostMatches(host, @"chatgpt.com")) return YES;
    return [host.lowercaseString isEqualToString:@"chat.openai.com"];
}

static BOOL CGExternalLinksIsInternalDestinationHost(NSString *host) {
    if (CGExternalLinksIsChatGPTHost(host)) return YES;

    // Keep the app's authentication path inside Gecko. Once authentication is
    // underway, the current selected page is no longer ChatGPT, so OAuth
    // provider navigation also remains untouched.
    NSArray<NSString *> *authHosts = @[
        @"auth.openai.com",
        @"auth0.openai.com",
        @"accounts.openai.com",
        @"login.openai.com",
        @"oauth.openai.com"
    ];

    for (NSString *candidate in authHosts) {
        if (CGExternalLinksHostMatches(host, candidate)) return YES;
    }
    return NO;
}

static BOOL CGExternalLinksShouldUseDefaultBrowser(NSURL *destination,
                                                    NSDictionary *options) {
    if (!CGExternalLinksIsOurApp() || !destination) return NO;

    id universalOnly = options[UIApplicationOpenURLOptionUniversalLinksOnly];
    if (![universalOnly respondsToSelector:@selector(boolValue)] ||
        ![universalOnly boolValue]) {
        return NO;
    }

    NSString *scheme = destination.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return NO;
    }

    NSURL *source = CGExternalLinksCurrentSelectedURL();
    if (!CGExternalLinksIsChatGPTHost(source.host)) {
        return NO;
    }

    if (CGExternalLinksIsInternalDestinationHost(destination.host)) {
        return NO;
    }

    return YES;
}

static void CGExternalLinksOpenURL(UIApplication *application,
                                   SEL selector,
                                   NSURL *url,
                                   NSDictionary *options,
                                   void (^completion)(BOOL)) {
    NSDictionary *effectiveOptions = options ?: @{};

    if (CGExternalLinksShouldUseDefaultBrowser(url, effectiveOptions)) {
        NSMutableDictionary *rewritten = [effectiveOptions mutableCopy];
        [rewritten removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];
        effectiveOptions = [rewritten copy];

        NSLog(@"[ChatGPTGecko] Handing external URL to default browser: %@",
              url.absoluteString);
    }

    if (CGOriginalUIApplicationOpenURL) {
        CGOriginalUIApplicationOpenURL(application,
                                       selector,
                                       url,
                                       effectiveOptions,
                                       completion);
    }
}

__attribute__((constructor))
static void CGExternalLinksInstall(void) {
    @autoreleasepool {
        if (!CGExternalLinksIsOurApp()) return;

        Method method =
            class_getInstanceMethod(UIApplication.class,
                                    @selector(openURL:options:completionHandler:));
        if (!method) {
            NSLog(@"[ChatGPTGecko] External-link handoff hook unavailable");
            return;
        }

        CGOriginalUIApplicationOpenURL =
            (CGUIApplicationOpenURLIMP)method_getImplementation(method);
        method_setImplementation(method, (IMP)CGExternalLinksOpenURL);

        NSLog(@"[ChatGPTGecko] Default-browser external-link handoff installed");
    }
}
