#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <sqlite3.h>

static NSString *const CGRoot = @"/var/mobile/Documents/ChatGPTNativeDiagnostics";
static const NSUInteger CGMaximumIPSBytes = 15000000;
static NSString *const CGTarget = @"com.551uk.chatgptios16";
static NSString *const CGHelper = @"com.551uk.chatgptios16.Helper";

static NSString *CGWhen(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    });
    @synchronized (formatter) { return [formatter stringFromDate:[NSDate date]]; }
}
static NSString *CGDigest(NSData *bytes) {
    if (!bytes) return @"unavailable";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *answer = [NSMutableString new];
    for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [answer appendFormat:@"%02x", digest[i]];
    return answer;
}
static NSString *CGShort(NSString *s) {
    if (s.length <= 160) return s ?: @"";
    return [s substringToIndex:160];
}

@interface CGNativeDiag : NSObject <UIDocumentPickerDelegate>
@property(nonatomic,strong) UIButton *bubble;
@property(nonatomic,strong) UIWindow *bubbleWindow;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) dispatch_queue_t worker;
@property(nonatomic,assign) BOOL scanning;
@property(nonatomic,assign) NSInteger newCrashes;
@property(nonatomic,assign) NSInteger knownCrashes;
@property(nonatomic,strong) NSString *lastScan;
@property(nonatomic,strong) NSString *lastError;
@property(nonatomic,assign) NSUInteger scans;
@property(nonatomic,assign) NSUInteger samples;
@property(nonatomic,assign) NSUInteger ticks;
@property(nonatomic,assign) int lastGeckoPID;
@property(nonatomic,strong) NSString *lastGeckoProcessType;
@property(nonatomic,assign) BOOL childWasVisible;
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSString *> *knownReportStats;
@property(nonatomic,strong) NSMutableSet<NSString *> *capturedHashes;
+ (instancetype)shared;
- (void)start;
@end

@implementation CGNativeDiag
+ (instancetype)shared {
    static CGNativeDiag *obj=nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{obj=[CGNativeDiag new];});
    return obj;
}
- (instancetype)init {
    if ((self=[super init])) {
        _worker=dispatch_queue_create("com.551uk.chatgpt.native.diag",DISPATCH_QUEUE_SERIAL);
        _capturedHashes=[NSMutableSet new];
        _knownReportStats=[NSMutableDictionary new];
        _lastScan=@"Never";
        _lastError=@"";
        NSError *error=nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:
            [CGRoot stringByAppendingPathComponent:@"incidents"]
            withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) _lastError=error.localizedDescription;
        NSArray *existing=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:
            [CGRoot stringByAppendingPathComponent:@"incidents"] error:nil];
        for (NSString *name in existing)
            if ([name hasSuffix:@".original.ips"]) {
                NSString *prefix=[name stringByReplacingOccurrencesOfString:@".original.ips" withString:@""];
                if (prefix.length) [_capturedHashes addObject:prefix];
            }
        _knownCrashes=_capturedHashes.count;
    }
    return self;
}
- (NSString *)file:(NSString *)name {return [CGRoot stringByAppendingPathComponent:name];}
- (void)appendEvent:(NSString *)event extra:(NSString *)extra {
    if (!event) return;
    NSString *path=[self file:@"events.log"];
    NSString *line=[NSString stringWithFormat:@"%@\t%@\t%@\n",CGWhen(),event,CGShort(extra)];
    NSFileManager *fm=[NSFileManager defaultManager];
    // Append-only event log: retained until user removes it in Filza.
    NSData *bytes=[line dataUsingEncoding:NSUTF8StringEncoding];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:path];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:bytes];
        [handle closeFile];
    } @catch (NSException *ex) { [handle closeFile]; }
}
- (uint64_t)memoryBytes {
    mach_task_basic_info_data_t info={0};
    mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t k=task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count);
    return k==KERN_SUCCESS ? info.resident_size : 0;
}
// Read the saved Gecko session in READ-ONLY mode. We store route type,
// hashed URL/title and session-blob length, never message or chat text.
// One snapshot on foreground/process start/exit, not per message.
- (NSString *)tabSnapshot {
    NSArray<NSString *> *dirs=NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory,NSUserDomainMask,YES);
    if (!dirs.count)return @"tab-store:no-app-support";
    NSString *path=[dirs[0] stringByAppendingPathComponent:
                      @"AppData/TabManagement/TabManagement"];
    sqlite3 *db=NULL;
    if (sqlite3_open_v2(path.UTF8String,&db,
        SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,NULL)!=SQLITE_OK) {
        if (db)sqlite3_close(db);
        return @"tab-store:unreadable";
    }
    sqlite3_busy_timeout(db,70);
    sqlite3_stmt *statement=NULL;
    NSString *answer=@"tab-store:no-selection";
    const char *sql=
        "SELECT t.url, t.title, length(t.tab_session_state),"
        " t.is_private, s.selected_tab_mode "
        "FROM tab_state s JOIN tabs t ON t.id=s.selected_regular_tab_id "
        "WHERE s.id=1 LIMIT 1";
    if (sqlite3_prepare_v2(db,sql,-1,&statement,NULL)==SQLITE_OK &&
        sqlite3_step(statement)==SQLITE_ROW) {
        const unsigned char *rawURL=sqlite3_column_text(statement,0);
        const unsigned char *rawTitle=sqlite3_column_text(statement,1);
        NSString *url=rawURL?[NSString stringWithUTF8String:(const char *)rawURL]:@"";
        NSString *title=rawTitle?[NSString stringWithUTF8String:(const char *)rawTitle]:@"";
        NSURLComponents *parts=[NSURLComponents componentsWithString:url];
        NSString *route=parts.path?:@"";
        NSString *kind=route.length<2?@"home":
            ([route hasPrefix:@"/c/"]?@"conversation":@"other");
        NSString *digest=CGDigest([url dataUsingEncoding:NSUTF8StringEncoding]);
        NSString *titleDigest=CGDigest([title dataUsingEncoding:NSUTF8StringEncoding]);
        int len=sqlite3_column_int(statement,2);
        int priv=sqlite3_column_int(statement,3);
        const unsigned char *mode=sqlite3_column_text(statement,4);
        answer=[NSString stringWithFormat:
            @"route=%@ url_hash=%@ title_hash=%@ restored_session_bytes=%d "
            "private=%d mode=%s",
            kind,[digest substringToIndex:MIN((NSUInteger)16,digest.length)],
            [titleDigest substringToIndex:MIN((NSUInteger)16,titleDigest.length)],
            len,priv,mode?(const char *)mode:"?"];
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    return answer;
}

// Called by Reynard's actual GeckoRuntimeImpl for every newly spawned
// child process (verified against its 0.19.0 Swift source). No polling.
- (void)geckoChildStarted:(NSNotification *)note {
    NSDictionary *info=note.userInfo?:@{};
    NSNumber *value=info[@"pid"];
    NSString *kind=info[@"processType"];
    if (![value isKindOfClass:NSNumber.class])return;
    int pid=value.intValue;
    if (pid<=0)return;
    dispatch_async(self.worker,^{
        self.lastGeckoPID=pid;
        self.lastGeckoProcessType=[kind isKindOfClass:NSString.class]?kind:@"unknown";
        self.childWasVisible=YES;
        [self appendEvent:@"gecko-child-start" extra:
          [NSString stringWithFormat:@"pid=%d type=%@ %@",
              pid,self.lastGeckoProcessType,[self tabSnapshot]]];
        [self recordTrigger:@"gecko-child-start"];
    });
}

// On saved tab changes or process events, preserve a minimal context
// without recording full URLs or conversation content.
- (void)recordTrigger:(NSString *)trigger {
    NSString *line=[NSString stringWithFormat:@"%@\t%@\t%@\n",
        CGWhen(),trigger,[self tabSnapshot]];
    NSString *path=[self file:@"session-recovery.tsv"];
    NSFileManager *fm=NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path])
        [fm createFileAtPath:path
            contents:[@"utc\tevent\tsession_state\n"
                dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle)return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch(NSException *e) {
        self.lastError=e.reason?:@"session recovery log failed";
    } @finally { [handle closeFile]; }
}

- (NSString *)recentContext:(NSString *)filename maxLines:(NSUInteger)maxLines {
    NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:[self file:filename]];
    if (!handle)return @"(none)\n";
    NSData *bytes=nil;
    @try {
        unsigned long long length=[handle seekToEndOfFile];
        unsigned long long start=length>40000?length-40000:0;
        [handle seekToFileOffset:start];
        bytes=[handle readDataToEndOfFile];
    } @catch (NSException *e) {} @finally { [handle closeFile]; }
    NSString *raw=[[NSString alloc]initWithData:bytes encoding:NSUTF8StringEncoding]?:@"";
    NSArray<NSString *> *rows=[raw componentsSeparatedByString:@"\n"];
    NSUInteger from=rows.count>maxLines?rows.count-maxLines:0;
    return [[rows subarrayWithRange:NSMakeRange(from,rows.count-from)]
            componentsJoinedByString:@"\n"];
}

- (NSString *)scriptPath {
    return @"/var/jb/Applications/ChatGPT.app/Frameworks/GeckoView.framework/Frameworks/extensions/readerview/chatgpt-app-shell.js";
}
- (NSString *)meta {
    NSFileManager *fm=[NSFileManager defaultManager];
    NSDictionary *info=[[NSBundle mainBundle] infoDictionary] ?: @{};
    NSString *appVersion=[NSString stringWithFormat:@"%@ (%@)",
      info[@"CFBundleShortVersionString"]?:@"?", info[@"CFBundleVersion"]?:@"?"];
    NSData *script=[NSData dataWithContentsOfFile:[self scriptPath] options:NSDataReadingMappedIfSafe error:nil];
    NSString *scriptDigest=CGDigest(script);
    NSString *manifest=[[self scriptPath] stringByDeletingLastPathComponent];
    manifest=[manifest stringByAppendingPathComponent:@"manifest.json"];
    NSDictionary *m=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifest]?:[NSData data] options:0 error:nil];
    NSString *geo=@"/var/jb/Applications/ChatGPT.app/Frameworks/XUL";
    NSDictionary *xul=[fm attributesOfItemAtPath:geo error:nil];
    NSString *gecko=@"/var/jb/Applications/ChatGPT.app/Frameworks/GeckoView.framework/Info.plist";
    NSDictionary *g=[NSDictionary dictionaryWithContentsOfFile:gecko];
    return [NSString stringWithFormat:
      @"ChatGPT Native Diagnostics v2.2\nCaptured UTC: %@\n"
      "Target bundle: %@\nCurrent bundle: %@\n"
      "App version: %@\nGeckoView version: %@\n"
      "iOS version: %@\nHardware model: %@\n"
      "App JS path: %@\nApp JS SHA-256: %@\nReaderView manifest version: %@\n"
      "XUL file size: %@ bytes\nXUL modified: %@\n"
      "Main app memory resident: %llu bytes\n"
      "Captured report count: %ld\nLast scan: %@\nLast error: %@\n"
      "Capture mode: automatic 5s foreground timeline and 10s crash scan; no launch daemon\n"
      "No per-message callbacks. No remote uploads.\n",
      CGWhen(),CGTarget,[[NSBundle mainBundle] bundleIdentifier]?:@"unknown",
      appVersion,g[@"CFBundleShortVersionString"]?:@"unknown",
      [UIDevice currentDevice].systemVersion,
      [UIDevice currentDevice].model,[self scriptPath],scriptDigest,
      [m isKindOfClass:NSDictionary.class]?(m[@"version"]?:@"unknown"):@"unavailable",
      xul[NSFileSize]?:@"unknown",xul[NSFileModificationDate]?:@"unknown",
      (unsigned long long)[self memoryBytes],(long)self.knownCrashes,
      self.lastScan,self.lastError];
}
- (BOOL)matchesReportData:(NSData *)data {
    if (!data.length || data.length>CGMaximumIPSBytes) return NO;
    NSString *s=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) return NO;
    return [s containsString:CGHelper] ||
       ([s containsString:@"/ChatGPT.app/PlugIns/Reynard Helper.appex/"] &&
        [s containsString:@"Reynard"]);
}
- (NSString *)firstValue:(NSString *)key inJSON:(NSDictionary *)dict {
    id value=dict[key];
    if ([value isKindOfClass:NSString.class])return value;
    if ([value respondsToSelector:@selector(stringValue)])return [value stringValue];
    return @"";
}
- (NSString *)analyzeData:(NSData *)bytes name:(NSString *)name hash:(NSString *)hash {
    NSString *text=[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]?:@"";
    NSArray<NSString *> *lines=[text componentsSeparatedByString:@"\n"];
    NSMutableString *out=[NSMutableString stringWithFormat:
      @"Crash diagnostic report\nCapture UTC: %@\nSource: %@\nSHA-256: %@\n"
      "Original .ips is preserved separately.\n\n",CGWhen(),name,hash];
    if (lines.count>0) {
        NSData *first=[lines[0] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *meta=[NSJSONSerialization JSONObjectWithData:first options:0 error:nil];
        if ([meta isKindOfClass:NSDictionary.class]) {
            for (NSString *key in @[@"timestamp",@"incident_id",@"bug_type",@"app_name",@"name",@"slice_uuid",@"os_version"]) {
                if (meta[key]) [out appendFormat:@"%@: %@\n",key,meta[key]];
            }
        }
    }
    // Apple .ips can contain two JSON objects, unlike a one-object JSON file.
    NSRange nl=[text rangeOfString:@"\n"];
    if (nl.location!=NSNotFound && text.length-nl.location<CGMaximumIPSBytes) {
        NSData *payload=[[text substringFromIndex:nl.location+1] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *body=[NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        if ([body isKindOfClass:NSDictionary.class]) {
            NSDictionary *exception=body[@"exception"];
            [out appendFormat:@"Exception: %@\nFaulting thread index: %@\n",
                [exception isKindOfClass:NSDictionary.class]?exception:@"unknown",
                body[@"faultingThread"]?:@"unknown"];
            NSArray *threads=body[@"threads"];
            NSNumber *idx=body[@"faultingThread"];
            if ([threads isKindOfClass:NSArray.class] && [idx isKindOfClass:NSNumber.class] &&
                idx.integerValue>=0 && idx.integerValue<threads.count) {
                NSDictionary *thread=threads[idx.integerValue];
                [out appendFormat:@"Thread name: %@\n",thread[@"name"]?:@"unknown"];
                NSArray *frames=thread[@"frames"];
                NSArray *images=body[@"usedImages"];
                for (NSUInteger i=0;i<MIN(frames.count,18);i++) {
                    NSDictionary *frame=frames[i];
                    NSString *image=@"unknown";
                    NSNumber *number=frame[@"imageIndex"];
                    if ([number isKindOfClass:NSNumber.class] && number.integerValue>=0 &&
                        number.integerValue<images.count) {
                        NSDictionary *im=images[number.integerValue];
                        image=im[@"name"]?:@"unknown";
                        if (i==0) [out appendFormat:@"Faulting image UUID: %@\n",im[@"uuid"]?:@"unknown"];
                    }
                    [out appendFormat:@"frame %lu: %@ %@ + %@\n",
                      (unsigned long)i,image,frame[@"symbol"]?:@"(unsymbolicated)",
                      frame[@"imageOffset"]?:@"?"];
                }
            }
        }
    }
    [out appendString:@"\nCrash signature:\n"];
    if ([text containsString:@"TraceJitFrames"])
        [out appendString:@"Gecko SpiderMonkey JIT frame tracing (TraceJitFrames)\n"];
    else if ([text containsString:@"EnterJit"])
        [out appendString:@"Gecko SpiderMonkey JIT execution (EnterJit)\n"];
    else if ([text containsString:@"XUL"])
        [out appendString:@"XUL native crash, exact function not present in text\n"];
    else
        [out appendString:@"No symbolicated Gecko frames: inspect original .ips\n"];
    for (NSString *marker in @[@"EXC_BAD_ACCESS",@"SIGSEGV",@"KERN_INVALID_ADDRESS",
                               @"DOM Worker",@"0x696e8e8",@"0x696c7e4"]) {
        if ([text containsString:marker]) [out appendFormat:@"Observed: %@\n",marker];
    }
    [out appendString:
      @"\nInterpretation limits: native stack shows WHERE the memory access failed, "
      "not WHICH JavaScript statement or Gecko internal bug originated it. "
      "Use this exact crash signature with runtime events and controlled builds "
      "to isolate JIT/worker causes. Injecting more JS into streaming messages "
      "would compromise that experiment.\n\n"];
    [out appendString:[self meta]];
    return out;
}
- (void)captureData:(NSData *)data sourceName:(NSString *)source {
    if (![self matchesReportData:data]) return;
    NSString *hash=CGDigest(data);
    NSString *prefix=[hash substringToIndex:MIN(hash.length,20)];
    if ([self.capturedHashes containsObject:prefix]) return;
    NSString *folder=[self file:@"incidents"];
    NSString *raw=[folder stringByAppendingPathComponent:[prefix stringByAppendingString:@".original.ips"]];
    NSString *analysis=[folder stringByAppendingPathComponent:[prefix stringByAppendingString:@".analysis.txt"]];
    if (![data writeToFile:raw atomically:YES]) {
        self.lastError=[NSString stringWithFormat:@"Failed writing %@",raw];return;
    }
    NSString *report=[self analyzeData:data name:source hash:hash];
    // Attach the nearest available foreground/child-process and tab-restore
    // events to each report. The original IPS remains byte-for-byte intact.
    NSString *context=[NSString stringWithFormat:
      @"

--- Recent native process + app lifecycle ---
%@"
      "
--- Recent Gecko session snapshots ---
%@"
      "
--- Recent runtime samples (main app, not Helper memory) ---
%@",
      [self recentContext:@"events.log" maxLines:40],
      [self recentContext:@"session-recovery.tsv" maxLines:20],
      [self recentContext:@"timeline.tsv" maxLines:16]];
    report=[report stringByAppendingString:context];
    [report writeToFile:analysis atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [report writeToFile:[self file:@"last-crash-analysis.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.capturedHashes addObject:prefix];
    self.newCrashes++;
    self.knownCrashes=self.capturedHashes.count;
    [self appendEvent:@"helper-crash-detected" extra:
      [NSString stringWithFormat:@"%@ %@ %@",prefix,source,[self tabSnapshot]]];
}
- (void)scan:(BOOL)manual {
    if (self.scanning) return;
    self.scanning=YES;
    dispatch_async(self.worker, ^{
        @autoreleasepool {
            NSFileManager *fm=[NSFileManager defaultManager];
            NSArray *paths=@[
                @"/var/mobile/Library/Logs/CrashReporter",
                @"/var/mobile/Library/Logs/CrashReporter/Retired",
                @"/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs",
                @"/var/mobile/Library/Logs/CrashReporter/Archived",
                @"/var/mobile/Library/Logs/DiagnosticReports"
            ];
            NSInteger examined=0, candidates=0;
            for (NSString *directory in paths) {
                NSArray *names=[fm contentsOfDirectoryAtPath:directory error:nil];
                if (!names) continue;
                NSMutableArray<NSDictionary *> *files=[NSMutableArray new];
                for (NSString *name in names) {
                    NSString *lower=name.lowercaseString;
                    if (!([lower hasSuffix:@".ips"]||[lower hasSuffix:@".crash"])) continue;
                    // Apple crash process name is Reynard Helper (custom bundle
                    // is confirmed from file contents, never filename alone).
                    if (![lower containsString:@"reynard"] &&
                        ![lower containsString:@"chatgpt"]) continue;
                    NSString *path=[directory stringByAppendingPathComponent:name];
                    NSDictionary *attr=[fm attributesOfItemAtPath:path error:nil];
                    if (![attr[NSFileType] isEqual:NSFileTypeRegular]) continue;
                    if ([attr[NSFileSize] unsignedLongLongValue]>CGMaximumIPSBytes) continue;
                    [files addObject:@{@"path":path,
                       @"date":attr[NSFileModificationDate]?:[NSDate distantPast]}];
                }
                [files sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
                    return [b[@"date"] compare:a[@"date"]];
                }];
                for (NSDictionary *item in files) {
                    if (examined>=120) break;
                    examined++;
                    // Read only new or changed IPS reports; avoid repeat hashes.
                    NSString *p=item[@"path"];
                    NSDictionary *attrs=[fm attributesOfItemAtPath:p error:nil];
                    NSString *signature=[NSString stringWithFormat:@"%@:%@",
                      attrs[NSFileSize]?:@0,[attrs[NSFileModificationDate] description]?:@""];
                    if ([self.knownReportStats[p] isEqualToString:signature]) continue;
                    NSData *bytes=[NSData dataWithContentsOfFile:p options:0 error:nil];
                    if (!bytes) continue;
                    self.knownReportStats[p]=signature;
                    candidates++;
                    [self captureData:bytes sourceName:p.lastPathComponent];
                }
            }
            self.scans++;
            self.lastScan=CGWhen();
            NSString *status=[NSString stringWithFormat:
              @"ChatGPT Native Diagnostics v2.2\nLast scan UTC: %@\n"
              "Scan count: %lu\nChecked recent report filenames: %ld\nNew/changed readable reports: %ld\n"
              "Matched and archived custom Helper reports: %ld\n"
              "Reports newly captured this session: %ld\nLast error: %@\n"
              "No launch daemon or Gecko message watcher; continuous foreground recording.\n"
              "If no system crash report is readable, use Import .ips.\n",
              self.lastScan,(unsigned long)self.scans,(long)examined,(long)candidates,
              (long)self.knownCrashes,(long)self.newCrashes,self.lastError];
            [status writeToFile:[self file:@"capture-status.txt"] atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
            [[self meta] writeToFile:[self file:@"build-info.txt"] atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
            if (manual)[self appendEvent:@"manual-capture" extra:
                [NSString stringWithFormat:@"checked=%ld known=%ld",(long)examined,(long)self.knownCrashes]];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.scanning=NO;
                [self updateLabel];
            });
        }
    });
}
// Process discovery is best-effort. iOS may restrict sysctl calls.
// The process name alone is NOT enough to identify our custom Helper;
// saved crash reports are attributed by bundle ID and complete path.
- (NSString *)helperCandidatePIDs {
    int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};
    size_t bytes=0;
    if (sysctl(mib,4,NULL,&bytes,NULL,0)!=0 || bytes==0)
        return [NSString stringWithFormat:@"unavailable:errno=%d",errno];
    struct kinfo_proc *procs=malloc(bytes);
    if (!procs) return @"unavailable:malloc";
    if (sysctl(mib,4,procs,&bytes,NULL,0)!=0) {
        int saved=errno;free(procs);
        return [NSString stringWithFormat:@"unavailable:errno=%d",saved];
    }
    NSMutableArray<NSString *> *ids=[NSMutableArray new];
    for (size_t i=0; i<bytes/sizeof(struct kinfo_proc); i++)
        if (strstr(procs[i].kp_proc.p_comm,"Reynard") != NULL)
            [ids addObject:[NSString stringWithFormat:@"%d",procs[i].kp_proc.p_pid]];
    free(procs);
    return ids.count?[ids componentsJoinedByString:@","]:@"none-visible";
}
- (void)appendTimelineSample:(NSString *)kind {
    NSString *path=[self file:@"timeline.tsv"];
    NSFileManager *fm=NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        NSData *header=[@"utc\tapp_state\tmain_resident_bytes\tcandidate_helper_pids\tevent\n"
            dataUsingEncoding:NSUTF8StringEncoding];
        [fm createFileAtPath:path contents:header attributes:nil];
    }
    NSString *state=UIApplication.sharedApplication.applicationState==UIApplicationStateActive?
       @"active":@"background-or-inactive";
    NSString *candidates=[self helperCandidatePIDs];
    if (self.lastGeckoPID>0 && ![candidates hasPrefix:@"unavailable"]) {
        NSString *needle=[NSString stringWithFormat:@"%d",self.lastGeckoPID];
        BOOL exists=[[candidates componentsSeparatedByString:@","] containsObject:needle];
        if (self.childWasVisible && !exists) {
            self.childWasVisible=NO;
            [self appendEvent:@"gecko-child-disappeared" extra:
              [NSString stringWithFormat:@"pid=%d type=%@ %@",
                 self.lastGeckoPID,self.lastGeckoProcessType,[self tabSnapshot]]];
            [self recordTrigger:@"gecko-child-disappeared"];
            // The iOS crash reporter may write its IPS a few seconds after
            // the process terminates; the existing 10s scan also continues.
        }
        if (exists) self.childWasVisible=YES;
    }
    NSString *line=[NSString stringWithFormat:@"%@\t%@\t%llu\t%@\t%@\n",
        CGWhen(),state,(unsigned long long)[self memoryBytes],
        candidates,kind?:@"sample"];
    NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) { self.lastError=@"Unable to open timeline.tsv"; return; }
    @try { [handle seekToEndOfFile]; [handle writeData:
        [line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch(NSException *ex) { self.lastError=ex.reason?:@"timeline write error"; }
    @finally { [handle closeFile]; }
    self.samples++;
}

- (void)writeHeartbeat:(NSString *)event {
    dispatch_async(self.worker, ^{
        NSString *s=[NSString stringWithFormat:
          @"ChatGPT Native Diagnostics v2.2\nApp is alive: %@\n"
          "App foregrounded: %@\nResident memory bytes: %llu\n"
          "No daemon. Next heartbeat only while app foregrounded.\n",
          CGWhen(),[UIApplication sharedApplication].applicationState==UIApplicationStateActive?@"yes":@"no",
          (unsigned long long)[self memoryBytes]];
        [s writeToFile:[self file:@"app-heartbeat.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self appendTimelineSample:event?:@"automatic-sample"];
        if (event)[self appendEvent:event extra:
            [NSString stringWithFormat:@"main-memory=%llu",(unsigned long long)[self memoryBytes]]];
    });
}
- (UIWindow *)hostWindow {
    UIApplication *app=UIApplication.sharedApplication;
    for (UIWindow *w in app.windows)
        if (w.windowLevel==UIWindowLevelNormal && w.rootViewController && !w.hidden) return w;
    return app.keyWindow;
}
- (void)updateLabel {
    if (!self.bubble)return;
    NSString *title=self.scanning?@"Scanning…":@"Diagnostics";
    [self.bubble setTitle:title forState:UIControlStateNormal];
}
- (void)installButton {
    UIWindow *window=[self hostWindow];
    if (!window) return;
    if (self.bubble.superview==window)return;
    [self.bubble removeFromSuperview];
    if (!self.bubble) {
        UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom];
        b.backgroundColor=[UIColor colorWithRed:.09 green:.19 blue:.36 alpha:.92];
        b.layer.cornerRadius=12;
        b.layer.shadowColor=UIColor.blackColor.CGColor;
        b.layer.shadowOpacity=.18;
        b.layer.shadowRadius=5;
        b.titleLabel.font=[UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [b addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(drag:)];
        [b addGestureRecognizer:pan];
        self.bubble=b;
    }
    CGSize size=window.bounds.size;
    // Center between the top-left sidebar control and top-right ellipsis,
    // at the highest point below the Dynamic Island/status-bar safe area.
    CGFloat topInset=MAX(window.safeAreaInsets.top,
                         UIApplication.sharedApplication.statusBarFrame.size.height);
    CGFloat buttonWidth=90.0, buttonHeight=30.0;
    CGFloat buttonTop=MAX(0.0,topInset)+1.0;
    self.bubble.frame=CGRectMake((size.width-buttonWidth)/2.0,buttonTop,
                                 buttonWidth,buttonHeight);
    [self updateLabel];
    [window addSubview:self.bubble];
    [window bringSubviewToFront:self.bubble];
}
- (void)drag:(UIPanGestureRecognizer *)pan {
    if (!self.bubble.superview)return;
    CGPoint delta=[pan translationInView:self.bubble.superview];
    CGPoint center=self.bubble.center;
    center.x=MAX(60,MIN(self.bubble.superview.bounds.size.width-60,center.x+delta.x));
    CGFloat minY=MAX(self.bubble.superview.safeAreaInsets.top,
                     UIApplication.sharedApplication.statusBarFrame.size.height)+16;
    center.y=MAX(minY,MIN(self.bubble.superview.bounds.size.height-75,center.y+delta.y));
    self.bubble.center=center;
    [pan setTranslation:CGPointZero inView:self.bubble.superview];
}
- (UIViewController *)presenter {
    UIViewController *vc=[self hostWindow].rootViewController;
    while (vc.presentedViewController)vc=vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class])
        vc=[(UINavigationController *)vc visibleViewController];
    if ([vc isKindOfClass:UITabBarController.class])
        vc=[(UITabBarController *)vc selectedViewController];
    return vc;
}
- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self presenter] presentViewController:a animated:YES completion:nil];
}
- (void)importIPS {
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.data",@"public.plain-text",@"public.json"]
        inMode:UIDocumentPickerModeImport];
    picker.delegate=self;
    [[self presenter] presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url=urls.firstObject;
    NSData *data=[NSData dataWithContentsOfURL:url options:0 error:nil];
    if (!data||data.length>CGMaximumIPSBytes) {
        [self alert:@"Import failed" message:@"File unavailable or larger than 15 MB."];
        return;
    }
    if (![self matchesReportData:data]) {
        [self alert:@"Not this Helper" message:@"The report does not identify com.551uk.chatgptios16.Helper. Only the custom ChatGPT Helper is collected."];
        return;
    }
    dispatch_async(self.worker, ^{
        [self captureData:data sourceName:url.lastPathComponent?:@"Imported.ips"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateLabel];
            [self alert:@"Crash report imported" message:@"Original report and analysis saved. Tap Export evidence to share them."];
        });
    });
}
- (void)share {
    // Export the latest completed snapshot; the Capture now action refreshes
    // files asynchronously before sharing, avoiding a race on partial writes.
    NSMutableArray *paths=[NSMutableArray arrayWithArray:@[
      [self file:@"build-info.txt"],[self file:@"capture-status.txt"],
      [self file:@"app-heartbeat.txt"],[self file:@"timeline.tsv"],
      [self file:@"session-recovery.tsv"],[self file:@"events.log"],
      [self file:@"events-previous.log"],[self file:@"last-crash-analysis.txt"]]];
    NSString *incident=[self file:@"incidents"];
    NSArray *names=[[[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:incident error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    // The last eight report sets suffice for first triage; full older files
    // remain accessible under Documents to share manually.
    NSInteger count=0;
    for (NSString *name in names.reverseObjectEnumerator)
        if ([name hasSuffix:@".ips"] && count++ < 8) {
            NSString *path=[incident stringByAppendingPathComponent:name];
            [paths addObject:path];
            NSString *a=[path stringByReplacingOccurrencesOfString:@".original.ips" withString:@".analysis.txt"];
            [paths addObject:a];
        }
    NSMutableArray *urls=[NSMutableArray new];
    NSFileManager *fm=[NSFileManager defaultManager];
    for (NSString *path in paths)
        if ([fm fileExistsAtPath:path]) [urls addObject:[NSURL fileURLWithPath:path]];
    if (!urls.count) {
        [self alert:@"No files yet" message:@"Tap Capture now, then Export evidence."];
        return;
    }
    UIActivityViewController *share=[[UIActivityViewController alloc]
         initWithActivityItems:urls applicationActivities:nil];
    UIPopoverPresentationController *pop=share.popoverPresentationController;
    pop.sourceView=self.bubble;pop.sourceRect=self.bubble.bounds;
    [[self presenter] presentViewController:share animated:YES completion:nil];
}
- (void)tapped {
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"ChatGPT Helper diagnostics"
       message:[NSString stringWithFormat:
         @"Custom Helper reports: %ld\nLast scan: %@\n"
         "No page/message monitoring. No launch daemon.\n"
         "Original .ips and events can be exported.",
         (long)self.knownCrashes,self.lastScan]
       preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weak=self;
    [menu addAction:[UIAlertAction actionWithTitle:@"Capture crash reports now"
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [weak scan:YES]; [weak writeHeartbeat:@"user-capture"];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Export evidence"
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[weak share];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Import .ips from Files"
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[weak importIPS];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Show status"
      style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *s=[NSString stringWithContentsOfFile:[weak file:@"capture-status.txt"]
          encoding:NSUTF8StringEncoding error:nil];
        [weak alert:@"Monitor status" message:s?:@"No scan yet. Select Capture now."];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Hide button until app restart"
      style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
        [weak.bubble removeFromSuperview];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel"
      style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop=menu.popoverPresentationController;
    pop.sourceView=self.bubble;pop.sourceRect=self.bubble.bounds;
    [[self presenter] presentViewController:menu animated:YES completion:nil];
}
- (void)tick:(NSTimer *)timer {
    if (UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    // Append one runtime sample every 5 seconds, continuously. Poll
    // for NEW Helper IPS files every 10 seconds. No tapping required.
    self.ticks++;
    [self writeHeartbeat:nil];
    if ((self.ticks % 2) == 0) [self scan:NO];
}
- (void)active:(NSNotification *)note {
    dispatch_async(self.worker, ^{ [self recordTrigger:@"app-active"]; });
    [self installButton];
    [self writeHeartbeat:@"app-active"];
    [self scan:NO];
    if (!self.timer)
        self.timer=[NSTimer scheduledTimerWithTimeInterval:5 target:self
              selector:@selector(tick:) userInfo:nil repeats:YES];
}
- (void)background:(NSNotification *)note {
    dispatch_async(self.worker, ^{ [self recordTrigger:@"app-background"]; });
    [self writeHeartbeat:@"app-background"];
}
- (void)memoryWarning:(NSNotification *)note {
    [self writeHeartbeat:@"main-app-memory-warning"];
}
- (void)start {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:CGTarget])return;
    NSNotificationCenter *n=NSNotificationCenter.defaultCenter;
    [n addObserver:self selector:@selector(geckoChildStarted:)
       name:@"GeckoRuntime.ChildProcessDidStart" object:nil];
    [n addObserver:self selector:@selector(active:)
       name:UIApplicationDidBecomeActiveNotification object:nil];
    [n addObserver:self selector:@selector(background:)
       name:UIApplicationDidEnterBackgroundNotification object:nil];
    [n addObserver:self selector:@selector(memoryWarning:)
       name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    dispatch_async(self.worker, ^{ [self recordTrigger:@"diagnostics-started"]; });
    [self writeHeartbeat:@"diagnostics-started"];
    if (UIApplication.sharedApplication.applicationState==UIApplicationStateActive)
        [self active:nil];
    else [self scan:NO];
}
@end

__attribute__((constructor))
static void CGNativeDiagnosticsInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[CGNativeDiag shared] start];
    });
}
