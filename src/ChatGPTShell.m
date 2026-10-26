// ChatGPT for iOS 16 - Gecko app shell over Reynard 0.19.0.
// This library is loaded by the app binary, not by MobileSubstrate.
// Keep Gecko's web contents, accounts, file pickers and website UI unchanged.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static NSString * const CGBundleID = @"com.551uk.chatgptgecko";
static IMP CGOriginalLayout = NULL;
static BOOL CGHookInstalled = NO;
static NSInteger CGInstallAttempts = 0;
static const void *CGConstraintsAdjustedKey = &CGConstraintsAdjustedKey;

static BOOL CGIsOurApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:CGBundleID];
}

static UIView *CGFindNamedView(UIView *root, NSString *fragment) {
    if (!root) return nil;
    NSString *type = NSStringFromClass([root class]);
    if ([type rangeOfString:fragment options:NSCaseInsensitiveSearch].location != NSNotFound)
        return root;
    for (UIView *child in root.subviews) {
        UIView *result = CGFindNamedView(child, fragment);
        if (result) return result;
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

    // Prevent the hidden address bar and bottom browser toolbar from reserving space.
    // Do not touch constraints inside the Gecko content or any website elements.
    if (![objc_getAssociatedObject(content, CGConstraintsAdjustedKey) boolValue]) {
        NSArray<NSLayoutConstraint *> *constraints = root.constraints.copy;
        for (NSLayoutConstraint *constraint in constraints) {
            if (constraint.firstItem == content || constraint.secondItem == content) {
                constraint.active = NO;
            }
        }
        content.translatesAutoresizingMaskIntoConstraints = YES;
        content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(content, CGConstraintsAdjustedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    chrome.hidden = YES;
    chrome.userInteractionEnabled = NO;
    if (overview) {
        overview.hidden = YES;
        overview.userInteractionEnabled = NO;
    }

    UIEdgeInsets safe = root.safeAreaInsets;
    CGRect bounds = root.bounds;
    CGFloat top = safe.top;
    CGFloat bottom = safe.bottom;
    // ChatGPT mobile web already includes its own chat header, composer, sidebar
    // and attach controls. Let it fill the available iPhone viewport.
    CGRect available = CGRectMake(0, top, CGRectGetWidth(bounds),
                                 MAX(0, CGRectGetHeight(bounds) - top - bottom));
    if (!CGRectEqualToRect(content.frame, available)) content.frame = available;
    [root bringSubviewToFront:content];
}

static void CGBrowserDidLayout(id self, SEL _cmd) {
    if (CGOriginalLayout) ((void (*)(id, SEL))CGOriginalLayout)(self, _cmd);
    CGApplyAppLayout((UIViewController *)self);
}

static void CGConfigurePreferences(void) {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [prefs setObject:@"https://chatgpt.com/" forKey:@"default.NewTabSettings.customNewTabURL"];
    [prefs setObject:@"lastTab" forKey:@"default.HomepageSettings.openingScreen"];
    [prefs setBool:NO forKey:@"default.HomepageSettings.showsRecommendations"];
    [prefs setBool:NO forKey:@"default.HomepageSettings.showsNewUpdates"];
    [prefs setBool:NO forKey:@"default.HomepageSettings.showsFavorites"];
    [prefs setBool:NO forKey:@"default.HomepageSettings.showsFrequentlyVisited"];
    // Don't spoof newer iOS versions: Gecko supplies its own up-to-date UA.
    [prefs synchronize];
}

static void CGInstallHook(void) {
    if (!CGIsOurApp() || CGHookInstalled) return;
    Class cls = NSClassFromString(@"Reynard.BrowserViewController");
    if (!cls) cls = objc_getClass("_TtC7Reynard21BrowserViewController");
    Method m = cls ? class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews)) : NULL;
    if (m) {
        CGOriginalLayout = method_getImplementation(m);
        if (CGOriginalLayout != (IMP)CGBrowserDidLayout) {
            method_setImplementation(m, (IMP)CGBrowserDidLayout);
        }
        CGHookInstalled = YES;
        NSLog(@"[ChatGPTGecko] ChatGPT shell installed");
        return;
    }
    if (++CGInstallAttempts < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ CGInstallHook(); });
    } else {
        NSLog(@"[ChatGPTGecko] BrowserViewController unavailable; leaving Gecko usable");
    }
}

__attribute__((constructor))
static void CGStart(void) {
    @autoreleasepool {
        if (!CGIsOurApp()) return;
        CGConfigurePreferences();
        dispatch_async(dispatch_get_main_queue(), ^{ CGInstallHook(); });
    }
}
