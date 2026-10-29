#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <sys/sysctl.h>

static NSString *const CGRoot = @"/var/mobile/Documents/ChatGPTNativeDiagnostics";
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
    NSDictionary *attr=[fm attributesOfItemAtPath:path error:nil];
    if ([attr[NSFileSize] unsignedLongLongValue]>600000) {
        [fm removeItemAtPath:[self file:@"events-previous.log"] error:nil];
        [fm moveItemAtPath:path toPath:[self file:@"events-previous.log"] error:nil];
    }
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
      @"ChatGPT Native Diagnostics v2.0\nCaptured UTC: %@\n"
      "Target bundle: %@\nCurrent bundle: %@\n"
      "App version: %@\nGeckoView version: %@\n"
      "iOS version: %@\nHardware model: %@\n"
      "App JS path: %@\nApp JS SHA-256: %@\nReaderView manifest version: %@\n"
      "XUL file size: %@ bytes\nXUL modified: %@\n"
      "Main app memory resident: %llu bytes\n"
      "Captured report count: %ld\nLast scan: %@\nLast error: %@\n"
      "Capture mode: on-demand and while app foregrounded, no launch daemon\n"
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
    if (!data.length || data.length>3000000) return NO;
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
    if (nl.location!=NSNotFound && text.length-nl.location<3000000) {
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
    [report writeToFile:analysis atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [report writeToFile:[self file:@"last-crash-analysis.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.capturedHashes addObject:prefix];
    self.newCrashes++;
    self.knownCrashes=self.capturedHashes.count;
    [self appendEvent:@"helper-crash-detected" extra:[NSString stringWithFormat:@"%@ %@",prefix,source]];
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
                    if ([attr[NSFileSize] unsignedLongLongValue]>3000000) continue;
                    [files addObject:@{@"path":path,
                       @"date":attr[NSFileModificationDate]?:[NSDate distantPast]}];
                }
                [files sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
                    return [b[@"date"] compare:a[@"date"]];
                }];
                for (NSDictionary *item in files) {
                    if (examined>=120) break;
                    examined++;
                    NSData *bytes=[NSData dataWithContentsOfFile:item[@"path"] options:0 error:nil];
                    if (!bytes)continue;
                    candidates++;
                    [self captureData:bytes sourceName:[item[@"path"] lastPathComponent]];
                }
            }
            self.scans++;
            self.lastScan=CGWhen();
            NSString *status=[NSString stringWithFormat:
              @"ChatGPT Native Diagnostics v2.0\nLast scan UTC: %@\n"
              "Scan count: %lu\nChecked candidate files: %ld\nReadable report data: %ld\n"
              "Matched and archived custom Helper reports: %ld\n"
              "Reports newly captured this session: %ld\nLast error: %@\n"
              "No launch daemon, periodic service or Gecko content watcher.\n"
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
- (void)writeHeartbeat:(NSString *)event {
    dispatch_async(self.worker, ^{
        NSString *s=[NSString stringWithFormat:
          @"ChatGPT Native Diagnostics v2.0\nApp is alive: %@\n"
          "App foregrounded: %@\nResident memory bytes: %llu\n"
          "No daemon. Next heartbeat only while app foregrounded.\n",
          CGWhen(),[UIApplication sharedApplication].applicationState==UIApplicationStateActive?@"yes":@"no",
          (unsigned long long)[self memoryBytes]];
        [s writeToFile:[self file:@"app-heartbeat.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
        b.layer.cornerRadius=13;
        b.layer.shadowColor=UIColor.blackColor.CGColor;
        b.layer.shadowOpacity=.18;
        b.layer.shadowRadius=5;
        b.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [b addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(drag:)];
        [b addGestureRecognizer:pan];
        self.bubble=b;
    }
    CGSize size=window.bounds.size;
    self.bubble.frame=CGRectMake(12,MAX(155,size.height*.47),112,43);
    [self updateLabel];
    [window addSubview:self.bubble];
    [window bringSubviewToFront:self.bubble];
}
- (void)drag:(UIPanGestureRecognizer *)pan {
    if (!self.bubble.superview)return;
    CGPoint delta=[pan translationInView:self.bubble.superview];
    CGPoint center=self.bubble.center;
    center.x=MAX(60,MIN(self.bubble.superview.bounds.size.width-60,center.x+delta.x));
    center.y=MAX(100,MIN(self.bubble.superview.bounds.size.height-75,center.y+delta.y));
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
    if (!data||data.length>3000000) {
        [self alert:@"Import failed" message:@"File unavailable or larger than 3 MB."];
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
      [self file:@"app-heartbeat.txt"],[self file:@"events.log"],
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
    [self writeHeartbeat:nil];
    [self scan:NO];
}
- (void)active:(NSNotification *)note {
    [self installButton];
    [self writeHeartbeat:@"app-active"];
    [self scan:NO];
    if (!self.timer)
        self.timer=[NSTimer scheduledTimerWithTimeInterval:30 target:self
              selector:@selector(tick:) userInfo:nil repeats:YES];
}
- (void)background:(NSNotification *)note {
    [self writeHeartbeat:@"app-background"];
}
- (void)memoryWarning:(NSNotification *)note {
    [self writeHeartbeat:@"main-app-memory-warning"];
}
- (void)start {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:CGTarget])return;
    NSNotificationCenter *n=NSNotificationCenter.defaultCenter;
    [n addObserver:self selector:@selector(active:)
       name:UIApplicationDidBecomeActiveNotification object:nil];
    [n addObserver:self selector:@selector(background:)
       name:UIApplicationDidEnterBackgroundNotification object:nil];
    [n addObserver:self selector:@selector(memoryWarning:)
       name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
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
