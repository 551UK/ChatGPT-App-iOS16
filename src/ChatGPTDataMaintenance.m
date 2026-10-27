#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sqlite3.h>

static CFStringRef const CGPrefsDomain = CFSTR("com.551uk.chatgpt.settings");
static NSString *const CGBundleID = @"com.551uk.chatgptios16";

static BOOL CGIsChatGPTApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:CGBundleID];
}

static BOOL CGReadBool(NSString *key, BOOL fallback) {
    CFPreferencesAppSynchronize(CGPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, CGPrefsDomain);
    if (!value) return fallback;

    BOOL result = fallback;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
        result = number != 0;
    }

    CFRelease(value);
    return result;
}

static void CGWriteBool(NSString *key, BOOL value) {
    CFPreferencesSetAppValue(
        (__bridge CFStringRef)key,
        value ? kCFBooleanTrue : kCFBooleanFalse,
        CGPrefsDomain);
    CFPreferencesAppSynchronize(CGPrefsDomain);
}

static BOOL CGSQLiteExec(NSString *path, NSArray<NSString *> *statements) {
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                        NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NO;
    }

    sqlite3_busy_timeout(db, 2500);
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);

    BOOL ok = YES;
    for (NSString *sql in statements) {
        if (sqlite3_exec(db, sql.UTF8String, NULL, NULL, NULL) != SQLITE_OK) {
            ok = NO;
        }
    }

    if (ok) {
        sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    } else {
        sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
    }

    sqlite3_close(db);
    return ok;
}

static NSString *CGApplicationSupportPath(void) {
    return NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
}

static NSArray<NSString *> *CGFindFilesNamed(NSString *filename) {
    if (!filename.length) return @[];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = NSHomeDirectory();
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:home];
    NSMutableArray<NSString *> *matches = [NSMutableArray array];

    for (NSString *relative in enumerator) {
        if ([[relative lastPathComponent] isEqualToString:filename]) {
            [matches addObject:[home stringByAppendingPathComponent:relative]];
        }
    }

    return matches;
}

static void CGClearReynardHistory(BOOL noHistory) {
    NSString *support = CGApplicationSupportPath();
    if (!support.length) return;

    NSString *historyDB =
        [support stringByAppendingPathComponent:@"AppData/History/History"];

    NSMutableArray<NSString *> *sql = [NSMutableArray arrayWithArray:@[
        @"DELETE FROM hide_from_suggestions;",
        @"DELETE FROM visits;",
        @"DELETE FROM history;",
        @"DROP TRIGGER IF EXISTS cg_chatgpt_no_local_history;"
    ]];

    if (noHistory) {
        // Reynard's HistoryStore first upserts into history, then creates a
        // visit. Ignoring the history insert causes that transaction to finish
        // without a persistent site/visit while normal page navigation remains.
        [sql addObject:
            @"CREATE TRIGGER cg_chatgpt_no_local_history "
             "BEFORE INSERT ON history "
             "BEGIN SELECT RAISE(IGNORE); END;"];
    }

    CGSQLiteExec(historyDB, sql);

    NSString *tabDB =
        [support stringByAppendingPathComponent:
         @"AppData/TabManagement/TabManagement"];
    CGSQLiteExec(tabDB, @[@"DELETE FROM recently_closed_tabs;"]);
}

static void CGApplyReynardNoHistoryPolicy(BOOL noHistory) {
    NSString *support = CGApplicationSupportPath();
    if (!support.length) return;

    NSString *historyDB =
        [support stringByAppendingPathComponent:@"AppData/History/History"];

    NSMutableArray<NSString *> *sql =
        [NSMutableArray arrayWithObject:
         @"DROP TRIGGER IF EXISTS cg_chatgpt_no_local_history;"];

    if (noHistory) {
        [sql addObject:
            @"CREATE TRIGGER cg_chatgpt_no_local_history "
             "BEFORE INSERT ON history "
             "BEGIN SELECT RAISE(IGNORE); END;"];
    }

    CGSQLiteExec(historyDB, sql);
}

static void CGClearGeckoVisitHistory(void) {
    for (NSString *placesDB in CGFindFilesNamed(@"places.sqlite")) {
        CGSQLiteExec(placesDB, @[
            @"DELETE FROM moz_historyvisits;",
            @"DELETE FROM moz_inputhistory;",
            @"UPDATE moz_places SET visit_count = 0;",
            @"UPDATE moz_places SET last_visit_date = NULL;"
        ]);
    }
}

static void CGWriteGeckoHistoryPreference(BOOL noHistory) {
    NSString *managedLine = noHistory
        ? @"user_pref(\"places.history.enabled\", false);"
        : @"user_pref(\"places.history.enabled\", true);";

    for (NSString *prefsPath in CGFindFilesNamed(@"prefs.js")) {
        NSString *profile = [prefsPath stringByDeletingLastPathComponent];
        NSString *userJS = [profile stringByAppendingPathComponent:@"user.js"];

        NSString *existing =
            [NSString stringWithContentsOfFile:userJS
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        NSMutableArray<NSString *> *lines =
            [[existing componentsSeparatedByCharactersInSet:
              NSCharacterSet.newlineCharacterSet] mutableCopy];

        NSIndexSet *managed = [lines indexesOfObjectsPassingTest:
            ^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
                return [line containsString:@"ChatGPT iOS 16 history policy"] ||
                       [line containsString:@"places.history.enabled"];
            }];

        if (managed.count) [lines removeObjectsAtIndexes:managed];

        [lines addObject:@"// ChatGPT iOS 16 history policy"];
        [lines addObject:managedLine];

        NSString *updated =
            [[[lines componentsJoinedByString:@"\n"]
              stringByTrimmingCharactersInSet:
              NSCharacterSet.newlineCharacterSet]
             stringByAppendingString:@"\n"];

        [updated writeToFile:userJS
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:nil];
    }
}

static void CGRemoveDirectoryContents(NSString *path) {
    if (!path.length) return;

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL directory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&directory] || !directory) return;

    for (NSString *entry in [fm contentsOfDirectoryAtPath:path error:nil]) {
        [fm removeItemAtPath:[path stringByAppendingPathComponent:entry]
                       error:nil];
    }
}

static void CGClearLoginSafeCache(void) {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    for (NSString *cachePath in NSSearchPathForDirectoriesInDomains(
             NSCachesDirectory, NSUserDomainMask, YES)) {
        CGRemoveDirectoryContents(cachePath);
    }

    // Gecko can keep network/startup cache directories inside its profile.
    // Only these explicitly cache-only directories are touched.
    NSString *home = NSHomeDirectory();
    NSDirectoryEnumerator<NSString *> *enumerator =
        [NSFileManager.defaultManager enumeratorAtPath:home];
    NSMutableArray<NSString *> *cacheDirs = [NSMutableArray array];

    for (NSString *relative in enumerator) {
        NSString *name = relative.lastPathComponent;
        if ([name isEqualToString:@"cache2"] ||
            [name isEqualToString:@"startupCache"]) {
            [cacheDirs addObject:[home stringByAppendingPathComponent:relative]];
            [enumerator skipDescendants];
        }
    }

    for (NSString *cacheDir in cacheDirs) {
        CGRemoveDirectoryContents(cacheDir);
    }
}

static void CGApplyHistoryPolicy(BOOL noHistory, BOOL clearExisting) {
    if (clearExisting) {
        CGClearReynardHistory(noHistory);
        CGClearGeckoVisitHistory();
    } else {
        CGApplyReynardNoHistoryPolicy(noHistory);
    }

    CGWriteGeckoHistoryPreference(noHistory);
}

__attribute__((constructor))
static void CGDataMaintenanceInit(void) {
    @autoreleasepool {
        if (!CGIsChatGPTApp()) return;

        BOOL noHistory = CGReadBool(@"dontSaveLocalHistory", NO);
        BOOL clearHistory = CGReadBool(@"pendingClearHistory", NO);
        BOOL clearCache = CGReadBool(@"pendingClearCache", NO);

        CGApplyHistoryPolicy(noHistory, clearHistory || noHistory);

        if (clearHistory) {
            CGWriteBool(@"pendingClearHistory", NO);
        }

        if (clearCache) {
            CGClearLoginSafeCache();
            CGWriteBool(@"pendingClearCache", NO);
        }

        // On a first-ever launch Reynard/Gecko can create their stores after
        // constructors run. Reapply only the history policy once after startup;
        // this does not clear cookies, auth/session state, site storage, or
        // permissions.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL currentNoHistory =
                CGReadBool(@"dontSaveLocalHistory", NO);
            CGApplyHistoryPolicy(currentNoHistory, currentNoHistory);
        });
    }
}
