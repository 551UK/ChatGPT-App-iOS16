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


// Clear App Data is a one-shot request, not a permanent launch policy.
// Even if a cache file is locked or missing, never repeat destructive cleanup
// automatically on subsequent normal starts. Users can manually retry.
enum {
    CGClearHistoryBit     = 1 << 0,
    CGClearCacheBit       = 1 << 1,
    CGClearPermissionsBit = 1 << 2,
    CGClearDownloadsBit   = 1 << 3,
    CGClearTabsBit        = 1 << 4,
    CGClearAllBits        = (1 << 5) - 1
};

static NSUInteger CGReadClearMask(void) {
    CFPreferencesAppSynchronize(CGPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR("pendingClearCategories"), CGPrefsDomain);
    if (!value) return 0;
    long long number = 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &number);
    }
    CFRelease(value);
    return number > 0 ? ((NSUInteger)number & CGClearAllBits) : 0;
}

static void CGWriteClearMask(NSUInteger mask) {
    int number = (int)(mask & CGClearAllBits);
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &number);
    CFPreferencesSetAppValue(CFSTR("pendingClearCategories"), value, CGPrefsDomain);
    CFRelease(value);
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

// Remove contents only; never delete the parent of a cache-only folder.
// Do not recursively clear the app's Documents or Application Support root.
static BOOL CGRemoveDirectoryContents(NSString *path) {
    if (!path.length) return YES;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL directory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&directory]) return YES;
    if (!directory) return NO;
    BOOL success = YES;
    for (NSString *entry in [fm contentsOfDirectoryAtPath:path error:nil]) {
        NSError *error = nil;
        if (![fm removeItemAtPath:[path stringByAppendingPathComponent:entry] error:&error]) {
            success = NO;
            NSLog(@"[ChatGPTGecko] Could not clear %@: %@", entry, error);
        }
    }
    return success;
}

static BOOL CGRemoveFileIfPresent(NSString *path) {
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    NSError *error = nil;
    BOOL done = [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    if (!done) NSLog(@"[ChatGPTGecko] Could not remove %@: %@", path, error);
    return done;
}

static BOOL CGSQLiteExecIfPresent(NSString *path, NSArray<NSString *> *statements) {
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    return CGSQLiteExec(path, statements);
}

static BOOL CGClearLoginSafeCache(void) {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    BOOL success = YES;
    for (NSString *cachePath in NSSearchPathForDirectoriesInDomains(
             NSCachesDirectory, NSUserDomainMask, YES)) {
        if (!CGRemoveDirectoryContents(cachePath)) success = NO;
    }

    // Gecko network/startup cache is distinct from cookies/DOM auth storage.
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
        if (!CGRemoveDirectoryContents(cacheDir)) success = NO;
    }

    // Reynard's native favicon cache stores DB records and image files here.
    NSString *favicons = [CGApplicationSupportPath()
        stringByAppendingPathComponent:@"AppData/Favicons"];
    if (!CGRemoveDirectoryContents(favicons)) success = NO;
    return success;
}

static BOOL CGClearWebsitePermissions(void) {
    NSString *support = CGApplicationSupportPath();
    BOOL success = CGSQLiteExecIfPresent(
        [support stringByAppendingPathComponent:@"AppData/SitePermissions/SitePermissions"],
        @[@"DELETE FROM site_permissions;"]);

    // Gecko keeps site permission decisions in permissions.sqlite, separate
    // from cookies.sqlite, web storage, saved logins and auth sessions.
    // Only the permission records are cleared, not the Gecko profile.
    for (NSString *path in CGFindFilesNamed(@"permissions.sqlite")) {
        if (!CGSQLiteExecIfPresent(path, @[@"DELETE FROM moz_perms;"])) success = NO;
    }
    return success;
}

static BOOL CGClearDownloads(void) {
    // Source parity: Reynard DownloadStore stores its manifest at AppData/
    // DownloadStore and download files inside Documents/Downloads.
    NSString *support = CGApplicationSupportPath();
    NSString *manifest = [support stringByAppendingPathComponent:@"AppData/DownloadStore"];
    NSString *directory = [NSHomeDirectory()
                           stringByAppendingPathComponent:@"Documents/Downloads"];
    BOOL files = CGRemoveDirectoryContents(directory);
    BOOL records = CGRemoveFileIfPresent(manifest);
    return files && records;
}

static BOOL CGClearOpenTabs(void) {
    NSString *support = CGApplicationSupportPath();
    NSString *tabs = [support stringByAppendingPathComponent:
                      @"AppData/TabManagement/TabManagement"];

    BOOL success = CGSQLiteExecIfPresent(tabs, @[
        @"DELETE FROM recently_closed_tabs;",
        @"DELETE FROM tabs;",
        @"UPDATE tab_state SET selected_regular_tab_id=NULL, "
         "selected_private_tab_id=NULL, selected_tab_mode='regular', "
         "last_tab_overview='regular' WHERE id=1;"
    ]);

    // The source creates an initial tab automatically when no tabs restore.
    // Remove stale thumbnails/navigation metadata for those closed tabs too.
    NSString *thumbnails = [support stringByAppendingPathComponent:
                            @"AppData/TabManagement/ThumbCache"];
    NSString *navigation = [support stringByAppendingPathComponent:
                            @"AppData/TabSessions"];
    if (!CGRemoveDirectoryContents(thumbnails)) success = NO;
    if (!CGRemoveDirectoryContents(navigation)) success = NO;
    return success;
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

// Called explicitly from CGStart before any startup tab is seeded.
// Do not turn this back into a constructor: that makes the order undefined.
void CGRunPendingDataMaintenance(void) {
    @autoreleasepool {
        if (!CGIsChatGPTApp()) return;

        BOOL noHistory = CGReadBool(@"dontSaveLocalHistory", NO);
        NSUInteger mask = CGReadClearMask();
        NSUInteger incomplete = mask;

        // Consume the request BEFORE touching any files. An error or launch
        // interruption must never leave cleanup re-armed for every startup:
        // that repeatedly removes Gecko caches and makes the home page flicker.
        if (mask) CGWriteClearMask(0);

        // Process the queued request before Reynard initializes Gecko and
        // opens its DB stores. Never touch cookies, session tokens, saved
        // passwords, storage/default, or ChatGPT's web-account data.
        if (mask & CGClearHistoryBit) {
            CGClearReynardHistory(noHistory);
            CGClearGeckoVisitHistory();
            incomplete &= ~CGClearHistoryBit;
        } else {
            CGApplyReynardNoHistoryPolicy(noHistory);
        }
        CGWriteGeckoHistoryPreference(noHistory);

        if (mask & CGClearCacheBit) {
            if (CGClearLoginSafeCache()) incomplete &= ~CGClearCacheBit;
        }
        if (mask & CGClearPermissionsBit) {
            if (CGClearWebsitePermissions()) incomplete &= ~CGClearPermissionsBit;
        }
        if (mask & CGClearDownloadsBit) {
            if (CGClearDownloads()) incomplete &= ~CGClearDownloadsBit;
        }
        if (mask & CGClearTabsBit) {
            if (CGClearOpenTabs()) incomplete &= ~CGClearTabsBit;
        }
        if (mask) {
            NSLog(@"[ChatGPTGecko] One-shot Clear App Data finished: requested=%lu failures=%lu (no automatic retries)",
                  (unsigned long)mask, (unsigned long)incomplete);
        }

        // Preserve the pre-existing Don't Save Local History setting.
        // On a first-ever launch Gecko may create a history DB after startup.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL currentNoHistory = CGReadBool(@"dontSaveLocalHistory", NO);
            CGApplyHistoryPolicy(currentNoHistory, currentNoHistory);
        });
    }
}
