#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static NSString * const CGDownloadStoreDidChange = @"DownloadStore.DidChange";
static NSString * const CGDownloadStoreDidStart = @"DownloadStore.DidStartDownload";
static NSString * const CGChatGPTBundleID = @"com.551uk.chatgptios16";

typedef NS_ENUM(NSInteger, CGDownloadPillMode) {
    CGDownloadPillModeHidden = 0,
    CGDownloadPillModeCompact,
    CGDownloadPillModeDownloading,
    CGDownloadPillModeCompleted,
};

static BOOL CGDownloadIsOurApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:CGChatGPTBundleID];
}

static UIWindow *CGDownloadMainWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *fallback = nil;
    for (UIWindow *window in app.windows) {
        if (window.hidden || window.alpha <= 0.01) continue;
        if (!fallback && window.windowLevel == UIWindowLevelNormal) fallback = window;
        if (window.isKeyWindow) return window;
    }
    return fallback ?: app.windows.firstObject;
}

static UIViewController *CGTopPresentedController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController) {
        return CGTopPresentedController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return CGTopPresentedController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return CGTopPresentedController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

static UIViewController *CGFindBrowserController(UIViewController *controller) {
    if (!controller) return nil;

    NSString *name = NSStringFromClass(controller.class);
    if ([name isEqualToString:@"Reynard.BrowserViewController"] ||
        [name hasSuffix:@".BrowserViewController"] ||
        [name isEqualToString:@"_TtC7Reynard21BrowserViewController"]) {
        return controller;
    }

    for (UIViewController *child in controller.children) {
        UIViewController *found = CGFindBrowserController(child);
        if (found) return found;
    }

    if (controller.presentedViewController) {
        UIViewController *found = CGFindBrowserController(controller.presentedViewController);
        if (found) return found;
    }

    return nil;
}

static NSArray<NSDictionary *> *CGDownloadManifestEntries(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return @[];

    NSString *path = [support stringByAppendingPathComponent:@"AppData/DownloadStore"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @[];

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (id entry in (NSArray *)object) {
        if ([entry isKindOfClass:NSDictionary.class]) [entries addObject:entry];
    }
    return entries;
}

static NSString *CGDownloadState(NSDictionary *entry) {
    NSString *state = [entry[@"state"] isKindOfClass:NSString.class] ? entry[@"state"] : nil;
    // Older persisted Reynard entries without a state are completed.
    return state.length ? state : @"completed";
}

static NSString *CGActiveDownloadFileName(void) {
    for (NSDictionary *entry in CGDownloadManifestEntries()) {
        if ([CGDownloadState(entry) isEqualToString:@"active"]) {
            NSString *name = [entry[@"fileName"] isKindOfClass:NSString.class] ? entry[@"fileName"] : nil;
            if (!name.length) {
                name = [entry[@"relativePath"] isKindOfClass:NSString.class] ? entry[@"relativePath"] : nil;
            }
            return name;
        }
    }
    return nil;
}

static BOOL CGHasStoredDownloads(void) {
    return CGDownloadManifestEntries().count > 0;
}

static NSURL *CGCompletedDownloadURL(NSString *preferredFileName) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) return nil;

    NSString *downloads = [documents stringByAppendingPathComponent:@"Downloads"];
    NSArray<NSDictionary *> *entries = CGDownloadManifestEntries();

    // First try the exact file that was active immediately before completion.
    if (preferredFileName.length) {
        for (NSDictionary *entry in entries) {
            if (![CGDownloadState(entry) isEqualToString:@"completed"]) continue;
            NSString *name = [entry[@"fileName"] isKindOfClass:NSString.class] ? entry[@"fileName"] : nil;
            if (![name isEqualToString:preferredFileName]) continue;
            NSString *relative = [entry[@"relativePath"] isKindOfClass:NSString.class] ? entry[@"relativePath"] : nil;
            if (!relative.length) relative = name;
            NSString *path = [downloads stringByAppendingPathComponent:relative ?: @""];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                return [NSURL fileURLWithPath:path];
            }
        }
        return nil;
    }

    // Fallback only for a very recently written completed file.
    NSDate *now = [NSDate date];
    for (NSDictionary *entry in entries) {
        if (![CGDownloadState(entry) isEqualToString:@"completed"]) continue;
        NSString *relative = [entry[@"relativePath"] isKindOfClass:NSString.class] ? entry[@"relativePath"] : nil;
        if (!relative.length) continue;
        NSString *path = [downloads stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSDate *modified = attributes[NSFileModificationDate];
        if (modified && [now timeIntervalSinceDate:modified] <= 15.0) {
            return [NSURL fileURLWithPath:path];
        }
    }
    return nil;
}

static BOOL CGViewHasConstantConstraint(UIView *view, NSLayoutAttribute attribute, CGFloat *constantOut) {
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.firstItem == view &&
            constraint.secondItem == nil &&
            constraint.firstAttribute == attribute) {
            if (constantOut) *constantOut = constraint.constant;
            return YES;
        }
    }
    return NO;
}

static UIButton *CGFindDownloadToolbarButtonInView(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:UIButton.class]) {
        NSString *className = NSStringFromClass(view.class);
        BOOL toolbarButton = [className hasSuffix:@".ToolbarButton"] ||
                             [className hasSuffix:@"ToolbarButton"];
        if (toolbarButton) {
            UIButton *button = (UIButton *)view;
            if ([button.accessibilityLabel isEqualToString:@"Downloads"]) {
                return button;
            }

            // Locale-independent fallback: the Reynard download button is the
            // only ToolbarButton with both a 18x2.5 progress track and a
            // variable-width fill view.
            BOOL hasTrack = NO;
            BOOL hasFill = NO;
            for (UIView *subview in button.subviews) {
                CGFloat width = 0, height = 0;
                BOOL constantWidth = CGViewHasConstantConstraint(subview, NSLayoutAttributeWidth, &width);
                BOOL constantHeight = CGViewHasConstantConstraint(subview, NSLayoutAttributeHeight, &height);
                if (constantWidth && constantHeight &&
                    fabs(width - 18.0) < 0.5 && fabs(height - 2.5) < 0.5) {
                    hasTrack = YES;
                } else if (constantWidth && !constantHeight &&
                           width >= 0.0 && width <= 18.5) {
                    hasFill = YES;
                }
            }
            if (hasTrack && hasFill) return button;
        }
    }

    for (UIView *subview in view.subviews) {
        UIButton *found = CGFindDownloadToolbarButtonInView(subview);
        if (found) return found;
    }
    return nil;
}

typedef struct {
    BOOL found;
    BOOL active;
    CGFloat progress;
} CGDownloadVisualState;

static CGDownloadVisualState CGReadReynardDownloadVisualState(void) {
    CGDownloadVisualState result = { NO, NO, 0.0 };
    UIWindow *window = CGDownloadMainWindow();
    UIButton *button = CGFindDownloadToolbarButtonInView(window);
    if (!button) return result;

    UIView *track = nil;
    UIView *fill = nil;
    CGFloat trackWidth = 0.0;
    CGFloat fillWidth = 0.0;

    for (UIView *subview in button.subviews) {
        CGFloat width = 0, height = 0;
        BOOL constantWidth = CGViewHasConstantConstraint(subview, NSLayoutAttributeWidth, &width);
        BOOL constantHeight = CGViewHasConstantConstraint(subview, NSLayoutAttributeHeight, &height);

        if (constantWidth && constantHeight &&
            fabs(width - 18.0) < 0.5 && fabs(height - 2.5) < 0.5) {
            track = subview;
            trackWidth = width;
        } else if (constantWidth && !constantHeight &&
                   width >= 0.0 && width <= 18.5) {
            fill = subview;
            fillWidth = width;
        }
    }

    result.found = track != nil && fill != nil;
    result.active = result.found && !track.hidden && !fill.hidden;
    if (trackWidth > 0.1) {
        result.progress = MIN(1.0, MAX(0.0, fillWidth / trackWidth));
    }
    return result;
}

@interface CGDownloadPillView : UIControl
@property(nonatomic,strong) UIView *iconBackground;
@property(nonatomic,strong) UIImageView *iconView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *fileLabel;
@property(nonatomic,strong) UIProgressView *progressView;
@property(nonatomic,strong) UIButton *actionButton;
@property(nonatomic,strong) NSLayoutConstraint *widthConstraint;
@property(nonatomic,strong) NSLayoutConstraint *heightConstraint;
@property(nonatomic,strong) NSLayoutConstraint *centerXConstraint;
@property(nonatomic,strong) NSLayoutConstraint *trailingConstraint;
@property(nonatomic,assign) CGDownloadPillMode mode;
- (void)attachToWindow:(UIWindow *)window;
- (void)showDownloadingProgress:(CGFloat)progress fileName:(NSString *)fileName;
- (void)showCompletedFileName:(NSString *)fileName;
- (void)showCompact;
- (void)hidePill;
@end

@implementation CGDownloadPillView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.97];
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.cornerRadius = 28.0;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.22;
    self.layer.shadowRadius = 14.0;
    self.layer.shadowOffset = CGSizeMake(0, 6);
    self.clipsToBounds = NO;
    self.alpha = 0.0;

    _iconBackground = [UIView new];
    _iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBackground.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _iconBackground.layer.cornerRadius = 20.0;
    _iconBackground.userInteractionEnabled = NO;
    [self addSubview:_iconBackground];

    _iconView = [UIImageView new];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.tintColor = UIColor.whiteColor;
    [_iconBackground addSubview:_iconView];

    _titleLabel = [UILabel new];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.80;
    [self addSubview:_titleLabel];

    _fileLabel = [UILabel new];
    _fileLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _fileLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    _fileLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    _fileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self addSubview:_fileLabel];

    _progressView = [UIProgressView new];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    _progressView.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    _progressView.progressTintColor = UIColor.whiteColor;
    _progressView.layer.cornerRadius = 1.5;
    _progressView.clipsToBounds = YES;
    [self addSubview:_progressView];

    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    _actionButton.tintColor = UIColor.whiteColor;
    _actionButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _actionButton.layer.cornerRadius = 18.0;
    [self addSubview:_actionButton];

    [NSLayoutConstraint activateConstraints:@[
        [_iconBackground.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
        [_iconBackground.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconBackground.widthAnchor constraintEqualToConstant:40.0],
        [_iconBackground.heightAnchor constraintEqualToConstant:40.0],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBackground.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBackground.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:21.0],
        [_iconView.heightAnchor constraintEqualToConstant:21.0],

        [_actionButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
        [_actionButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_actionButton.widthAnchor constraintEqualToConstant:36.0],
        [_actionButton.heightAnchor constraintEqualToConstant:36.0],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBackground.trailingAnchor constant:12.0],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_actionButton.leadingAnchor constant:-10.0],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:11.0],

        [_fileLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_fileLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_fileLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1.0],

        [_progressView.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_progressView.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_progressView.topAnchor constraintEqualToAnchor:_fileLabel.bottomAnchor constant:7.0],
        [_progressView.heightAnchor constraintEqualToConstant:3.0],
    ]];

    _widthConstraint = [self.widthAnchor constraintEqualToConstant:282.0];
    _heightConstraint = [self.heightAnchor constraintEqualToConstant:72.0];
    [_widthConstraint setActive:YES];
    [_heightConstraint setActive:YES];

    return self;
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window) return;
    if (self.superview == window) return;

    [self removeFromSuperview];
    [window addSubview:self];

    CGFloat expandedWidth = MIN(300.0, MAX(250.0, CGRectGetWidth(window.bounds) - 42.0));
    self.widthConstraint.constant = expandedWidth;

    self.centerXConstraint = [self.centerXAnchor constraintEqualToAnchor:window.centerXAnchor];
    self.trailingConstraint = [self.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-10.0];

    [NSLayoutConstraint activateConstraints:@[
        [self.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:8.0],
        self.centerXConstraint
    ]];
}

- (void)applyMode:(CGDownloadPillMode)mode animated:(BOOL)animated {
    if (!self.superview) return;
    self.mode = mode;

    BOOL compact = mode == CGDownloadPillModeCompact;
    BOOL hidden = mode == CGDownloadPillModeHidden;

    if (compact) {
        self.centerXConstraint.active = NO;
        self.trailingConstraint.active = YES;
        self.widthConstraint.constant = 46.0;
        self.heightConstraint.constant = 46.0;
        self.layer.cornerRadius = 23.0;
        self.iconBackground.backgroundColor = UIColor.clearColor;
        self.iconBackground.layer.cornerRadius = 0.0;
        self.titleLabel.hidden = YES;
        self.fileLabel.hidden = YES;
        self.progressView.hidden = YES;
        self.actionButton.hidden = YES;
        self.iconView.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
    } else {
        self.trailingConstraint.active = NO;
        self.centerXConstraint.active = YES;
        CGFloat targetWidth = MIN(300.0, MAX(250.0, CGRectGetWidth(self.superview.bounds) - 42.0));
        self.widthConstraint.constant = targetWidth;
        self.heightConstraint.constant = 72.0;
        self.layer.cornerRadius = 28.0;
        self.iconBackground.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        self.iconBackground.layer.cornerRadius = 20.0;
        self.titleLabel.hidden = NO;
        self.fileLabel.hidden = NO;
        self.progressView.hidden = NO;
        self.actionButton.hidden = NO;
    }

    void (^changes)(void) = ^{
        [self.superview layoutIfNeeded];
        self.alpha = hidden ? 0.0 : 1.0;
        self.transform = hidden ? CGAffineTransformMakeTranslation(0, -10.0) : CGAffineTransformIdentity;
    };

    if (animated) {
        [UIView animateWithDuration:0.26
                              delay:0.0
             usingSpringWithDamping:0.88
              initialSpringVelocity:0.2
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (void)showDownloadingProgress:(CGFloat)progress fileName:(NSString *)fileName {
    NSInteger percent = (NSInteger)lround(MIN(1.0, MAX(0.0, progress)) * 100.0);
    self.iconView.image = [UIImage systemImageNamed:@"arrow.down"];
    self.titleLabel.text = [NSString stringWithFormat:@"Downloading %ld%%", (long)percent];
    self.fileLabel.text = fileName.length ? fileName : @"Download";
    [self.progressView setProgress:MIN(1.0, MAX(0.0, progress)) animated:YES];

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];
    [self.actionButton setImage:[UIImage systemImageNamed:@"folder.fill" withConfiguration:config] forState:UIControlStateNormal];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", self.titleLabel.text, self.fileLabel.text];
    [self applyMode:CGDownloadPillModeDownloading animated:YES];
}

- (void)showCompletedFileName:(NSString *)fileName {
    self.iconView.image = [UIImage systemImageNamed:@"checkmark"];
    self.titleLabel.text = @"Downloaded";
    self.fileLabel.text = fileName.length ? fileName : @"Tap to open";
    [self.progressView setProgress:1.0 animated:YES];

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];
    [self.actionButton setImage:[UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:config] forState:UIControlStateNormal];
    self.accessibilityLabel = [NSString stringWithFormat:@"Downloaded, %@", self.fileLabel.text];
    [self applyMode:CGDownloadPillModeCompleted animated:YES];
}

- (void)showCompact {
    self.accessibilityLabel = @"Downloads";
    [self applyMode:CGDownloadPillModeCompact animated:YES];
}

- (void)hidePill {
    [self applyMode:CGDownloadPillModeHidden animated:YES];
}

@end

@interface CGDownloadOverlayController : NSObject
@property(nonatomic,strong) CGDownloadPillView *pill;
@property(nonatomic,assign) BOOL wasActive;
@property(nonatomic,copy) NSString *activeFileName;
@property(nonatomic,strong) NSURL *lastCompletedURL;
@property(nonatomic,assign) NSUInteger completionGeneration;
@end

@implementation CGDownloadOverlayController

+ (instancetype)shared {
    static CGDownloadOverlayController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [CGDownloadOverlayController new];
    });
    return controller;
}

- (void)start {
    if (!CGDownloadIsOurApp()) return;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(downloadDidStart:)
                   name:CGDownloadStoreDidStart
                 object:nil];
    [center addObserver:self
               selector:@selector(downloadDidChange:)
                   name:CGDownloadStoreDidChange
                 object:nil];
    [center addObserver:self
               selector:@selector(appDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refreshFromReynard];
    });
}

- (void)ensurePill {
    UIWindow *window = CGDownloadMainWindow();
    if (!window) return;

    if (!self.pill) {
        self.pill = [CGDownloadPillView new];
        [self.pill addTarget:self
                      action:@selector(handlePillTap:)
            forControlEvents:UIControlEventTouchUpInside];
        [self.pill.actionButton addTarget:self
                                   action:@selector(handleActionTap:)
                         forControlEvents:UIControlEventTouchUpInside];
    }
    [self.pill attachToWindow:window];
}

- (void)downloadDidStart:(NSNotification *)notification {
    (void)notification;
    self.wasActive = YES;
    self.activeFileName = CGActiveDownloadFileName();
    [self ensurePill];
    [self.pill showDownloadingProgress:0.0 fileName:self.activeFileName];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refreshFromReynard];
    });
}

- (void)downloadDidChange:(NSNotification *)notification {
    (void)notification;
    // Reynard's DownloadsCoordinator receives the same notification and updates
    // its hidden ToolbarButton from DownloadStore.currentSnapshot(). Read it on
    // the next main-loop turn so our percentage is the exact same progress.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.025 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refreshFromReynard];
    });
}

- (void)appDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refreshFromReynard];
    });
}

- (void)refreshFromReynard {
    if (!CGDownloadIsOurApp()) return;
    [self ensurePill];
    if (!self.pill) return;

    NSString *manifestActiveName = CGActiveDownloadFileName();
    CGDownloadVisualState visual = CGReadReynardDownloadVisualState();
    BOOL active = visual.active || manifestActiveName.length > 0;

    if (active) {
        self.wasActive = YES;
        if (manifestActiveName.length) self.activeFileName = manifestActiveName;
        CGFloat progress = visual.found ? visual.progress : self.pill.progressView.progress;
        [self.pill showDownloadingProgress:progress fileName:self.activeFileName];
        return;
    }

    if (self.wasActive) {
        self.wasActive = NO;
        NSURL *completedURL = CGCompletedDownloadURL(self.activeFileName);
        NSString *completedName = completedURL.lastPathComponent ?: self.activeFileName;

        self.lastCompletedURL = completedURL;
        self.activeFileName = nil;

        if (completedURL) {
            [self.pill showCompletedFileName:completedName];
            NSUInteger generation = ++self.completionGeneration;

            // Hand the finished file straight to iOS after the pill has visibly
            // entered its completed state. The sheet uses the exact downloaded
            // file URL and matches Reynard's own fallback opening behavior.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != self.completionGeneration) return;
                [self presentShareForURL:completedURL attempt:0];
            });

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != self.completionGeneration) return;
                if (CGHasStoredDownloads()) [self.pill showCompact];
                else [self.pill hidePill];
            });
        } else if (CGHasStoredDownloads()) {
            [self.pill showCompact];
        } else {
            [self.pill hidePill];
        }
        return;
    }

    if (CGHasStoredDownloads()) {
        [self.pill showCompact];
    } else {
        [self.pill hidePill];
    }
}

- (void)presentShareForURL:(NSURL *)url attempt:(NSInteger)attempt {
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return;

    UIWindow *window = CGDownloadMainWindow();
    UIViewController *presenter = CGTopPresentedController(window.rootViewController);
    if (!presenter || !presenter.view.window) {
        if (attempt < 4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self presentShareForURL:url attempt:attempt + 1];
            });
        }
        return;
    }

    // Do not stack another share sheet if the first completion callback races.
    if ([presenter isKindOfClass:UIActivityViewController.class]) return;

    UIActivityViewController *sheet =
        [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                         applicationActivities:nil];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.pill;
        popover.sourceRect = self.pill.bounds;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)openDownloadsManager {
    UIWindow *window = CGDownloadMainWindow();
    UIViewController *browser = CGFindBrowserController(window.rootViewController);
    SEL selector = NSSelectorFromString(@"showDownloadsKeyCommand:");
    if (browser && [browser respondsToSelector:selector]) {
        ((void (*)(id,SEL,id))objc_msgSend)(browser, selector, nil);
    }
}

- (void)handlePillTap:(id)sender {
    (void)sender;
    if (self.pill.mode == CGDownloadPillModeCompleted && self.lastCompletedURL) {
        [self presentShareForURL:self.lastCompletedURL attempt:0];
        return;
    }
    [self openDownloadsManager];
}

- (void)handleActionTap:(id)sender {
    (void)sender;
    if (self.pill.mode == CGDownloadPillModeCompleted && self.lastCompletedURL) {
        [self presentShareForURL:self.lastCompletedURL attempt:0];
    } else {
        [self openDownloadsManager];
    }
}

@end

__attribute__((constructor))
static void CGDownloadOverlayStart(void) {
    @autoreleasepool {
        if (!CGDownloadIsOurApp()) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[CGDownloadOverlayController shared] start];
        });
    }
}
