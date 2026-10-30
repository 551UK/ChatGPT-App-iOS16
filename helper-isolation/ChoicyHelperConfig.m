#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const KHelperID=@"com.551uk.chatgptios16.Helper";
static NSString *const KMainID=@"com.551uk.chatgptios16";
static NSString *const KPrefsName=@"com.opa334.choicyprefs.plist";
static NSString *const KBackupName=@"com.551uk.chatgpt-helper-isolation.backup.plist";
static NSString *const KStatus=@"/var/mobile/Documents/ChatGPTNativeDiagnostics/choicy-helper-isolation-status.txt";

static void logStatus(NSString *event,NSString *details) {
    NSDateFormatter *date=[NSDateFormatter new];
    date.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    date.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
    date.dateFormat=@"yyyy-MM-dd'T'HH:mm:ss'Z'";
    NSString *line=[NSString stringWithFormat:@"%@\t%@\t%@\n",
        [date stringFromDate:NSDate.date],event,details?:@""];
    NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[KStatus stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:KStatus])
        [fm createFileAtPath:KStatus contents:nil attributes:nil];
    NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:KStatus];
    if (h) {
        @try {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch(NSException *e) {}
        @finally { [h closeFile]; }
    }
    puts(line.UTF8String);
}
static NSString *prefsPath(void) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray<NSString *> *places=@[
        @"/var/mobile/Library/Preferences",
        @"/var/jb/var/mobile/Library/Preferences"
    ];
    for (NSString *dir in places) {
        NSString *p=[dir stringByAppendingPathComponent:KPrefsName];
        if ([fm fileExistsAtPath:p])return p;
    }
    return [places[0] stringByAppendingPathComponent:KPrefsName];
}
static BOOL helperMatches(void) {
    NSString *root=@"/var/jb/Applications/ChatGPT.app";
    NSDictionary *app=[NSDictionary dictionaryWithContentsOfFile:
        [root stringByAppendingPathComponent:@"Info.plist"]];
    NSDictionary *helper=[NSDictionary dictionaryWithContentsOfFile:
        [root stringByAppendingPathComponent:
            @"PlugIns/Reynard Helper.appex/Info.plist"]];
    return [app[@"CFBundleIdentifier"] isEqual:KMainID] &&
           [helper[@"CFBundleIdentifier"] isEqual:KHelperID];
}
static void notifyChoicy(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.opa334.choicyprefs/ReloadPrefs"),NULL,NULL,YES);
}
static BOOL savePrefs(NSDictionary *prefs,NSString *path) {
    struct stat st={0};
    BOOL exists=stat(path.fileSystemRepresentation,&st)==0;
    BOOL saved=[prefs writeToFile:path atomically:YES];
    if (!saved)return NO;
    if (geteuid()==0) {
        chown(path.fileSystemRepresentation,exists?st.st_uid:501,
              exists?st.st_gid:501);
        chmod(path.fileSystemRepresentation,exists?(st.st_mode&0777):0644);
    }
    return YES;
}
static BOOL change(BOOL enable) {
    if (enable && !helperMatches()) {
        logStatus(@"ERROR",@"Target ChatGPT and Helper IDs do not match. No preferences changed.");
        return NO;
    }
    NSString *path=prefsPath();
    NSString *backup=[[path stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:KBackupName];
    NSFileManager *fm=NSFileManager.defaultManager;
    BOOL existed=[fm fileExistsAtPath:path];
    NSDictionary *read=[NSDictionary dictionaryWithContentsOfFile:path];
    if (existed && ![read isKindOfClass:NSDictionary.class]) {
        logStatus(@"ERROR",@"Choicy preferences unreadable; refusing overwrite.");
        return NO;
    }
    NSMutableDictionary *top=[read mutableCopy]?:[NSMutableDictionary new];
    id rawApps=top[@"appSettings"];
    if (rawApps && ![rawApps isKindOfClass:NSDictionary.class]) {
        logStatus(@"ERROR",@"Choicy appSettings unexpectedly invalid.");
        return NO;
    }
    NSMutableDictionary *apps=[rawApps mutableCopy]?:[NSMutableDictionary new];
    id rawHelper=apps[KHelperID];
    if (rawHelper && ![rawHelper isKindOfClass:NSDictionary.class]) {
        logStatus(@"ERROR",@"Choicy Helper preference unexpectedly invalid.");
        return NO;
    }
    NSMutableDictionary *settings=[rawHelper mutableCopy]?:[NSMutableDictionary new];
    if (enable) {
        if (![fm fileExistsAtPath:backup]) {
            id previous=settings[@"tweakInjectionDisabled"];
            NSDictionary *restore=@{
                @"hadEntry":@(rawHelper!=nil),
                @"hadValue":@(previous!=nil),
                @"previousValue":previous?:@NO
            };
            if (!savePrefs(restore,backup)) {
                logStatus(@"ERROR",@"Could not preserve original Helper preference.");
                return NO;
            }
        }
        settings[@"tweakInjectionDisabled"]=@YES;
        apps[KHelperID]=[settings copy];
        top[@"appSettings"]=[apps copy];
        if (!savePrefs(top,path)) {
            logStatus(@"ERROR",@"Could not update Choicy preference file.");
            return NO;
        }
        NSDictionary *verified=[NSDictionary dictionaryWithContentsOfFile:path];
        id saved=((NSDictionary *)((NSDictionary *)verified[@"appSettings"])[KHelperID])[@"tweakInjectionDisabled"];
        if (![saved respondsToSelector:@selector(boolValue)] || ![saved boolValue]) {
            logStatus(@"ERROR",@"Choicy preference readback failed.");
            return NO;
        }
        notifyChoicy();
        logStatus(@"ENABLED",[NSString stringWithFormat:
            @"Only %@ has tweak injection disabled. Main ChatGPT untouched. File=%@",
            KHelperID,path]);
        return YES;
    }
    NSDictionary *restore=[NSDictionary dictionaryWithContentsOfFile:backup];
    if (![restore isKindOfClass:NSDictionary.class]) {
        logStatus(@"NO-RESTORE",@"No saved original setting; user preferences unchanged.");
        return YES;
    }
    if ([settings[@"tweakInjectionDisabled"] boolValue]) {
        if ([restore[@"hadValue"] boolValue])
            settings[@"tweakInjectionDisabled"]=restore[@"previousValue"]?:@NO;
        else [settings removeObjectForKey:@"tweakInjectionDisabled"];
        if (!settings.count && ![restore[@"hadEntry"] boolValue])
            [apps removeObjectForKey:KHelperID];
        else apps[KHelperID]=[settings copy];
        top[@"appSettings"]=[apps copy];
        if (!savePrefs(top,path)) {
            logStatus(@"ERROR",@"Failed restoring Choicy Helper preference.");
            return NO;
        }
        notifyChoicy();
    }
    [fm removeItemAtPath:backup error:nil];
    logStatus(@"RESTORED",@"Reverted only this package's Helper setting; unrelated preferences preserved.");
    return YES;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if (argc!=2)return 2;
        NSString *mode=[NSString stringWithUTF8String:argv[1]];
        if (![mode isEqual:@"enable"] && ![mode isEqual:@"restore"])return 2;
        return change([mode isEqual:@"enable"])?0:1;
    }
}
