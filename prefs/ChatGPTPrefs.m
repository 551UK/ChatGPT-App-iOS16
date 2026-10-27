#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <dlfcn.h>

static CFStringRef const CGPrefsDomain = CFSTR("com.551uk.chatgpt.settings");

static NSString *const CGChatGPTBundleID = @"com.551uk.chatgptios16";
static NSString *const CGAppearanceURL = @"https://chatgpt.com/settings/appearance";

static NSURL *CGChatGPTDataContainerURL(void) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySelector]) return nil;

    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)proxyClass, proxySelector, CGChatGPTBundleID);
    if (!proxy) return nil;

    SEL containerSelector = NSSelectorFromString(@"dataContainerURL");
    if (![proxy respondsToSelector:containerSelector]) return nil;

    return ((id (*)(id, SEL))objc_msgSend)(proxy, containerSelector);
}

static BOOL CGBindText(sqlite3_stmt *stmt, int index, NSString *value) {
    if (!stmt || !value) return NO;
    return sqlite3_bind_text(stmt,
                             index,
                             value.UTF8String,
                             -1,
                             SQLITE_TRANSIENT) == SQLITE_OK;
}

static BOOL CGPrepareAppearanceTab(NSString **errorMessage) {
    NSURL *container = CGChatGPTDataContainerURL();
    if (!container) {
        if (errorMessage) *errorMessage = @"Could not locate the ChatGPT app data container.";
        return NO;
    }

    NSURL *databaseURL = [[[[container URLByAppendingPathComponent:@"Library" isDirectory:YES]
        URLByAppendingPathComponent:@"Application Support" isDirectory:YES]
        URLByAppendingPathComponent:@"AppData/TabManagement" isDirectory:YES]
        URLByAppendingPathComponent:@"TabManagement" isDirectory:NO];

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(databaseURL.path.UTF8String,
                        &db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                        NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        if (errorMessage) *errorMessage = @"Could not open ChatGPT's saved tab database.";
        return NO;
    }

    sqlite3_busy_timeout(db, 2500);

    BOOL ok = sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", NULL, NULL, NULL) == SQLITE_OK;
    NSString *tabID = nil;

    if (ok) {
        sqlite3_stmt *stmt = NULL;
        const char *sql =
            "SELECT selected_regular_tab_id FROM tab_state WHERE id=1 LIMIT 1;";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK &&
            sqlite3_step(stmt) == SQLITE_ROW) {
            const char *value = (const char *)sqlite3_column_text(stmt, 0);
            if (value) tabID = [NSString stringWithUTF8String:value];
        }
        sqlite3_finalize(stmt);
    }

    if (ok && !tabID.length) {
        sqlite3_stmt *stmt = NULL;
        const char *sql =
            "SELECT id FROM tabs WHERE is_private=0 ORDER BY position ASC LIMIT 1;";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK &&
            sqlite3_step(stmt) == SQLITE_ROW) {
            const char *value = (const char *)sqlite3_column_text(stmt, 0);
            if (value) tabID = [NSString stringWithUTF8String:value];
        }
        sqlite3_finalize(stmt);
    }

    if (ok && !tabID.length) {
        tabID = NSUUID.UUID.UUIDString;
        sqlite3_stmt *stmt = NULL;
        const char *sql =
            "INSERT INTO tabs "
            "(id,title,url,created_at,opened_from,tab_session_state,is_muted,is_private,position) "
            "VALUES (?, 'Appearance', ?, ?, NULL, NULL, 0, 0, "
            "COALESCE((SELECT MAX(position)+1 FROM tabs WHERE is_private=0),0));";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
            !CGBindText(stmt, 1, tabID) ||
            !CGBindText(stmt, 2, CGAppearanceURL)) {
            ok = NO;
        } else {
            sqlite3_bind_double(stmt, 3, [NSDate date].timeIntervalSince1970);
            ok = sqlite3_step(stmt) == SQLITE_DONE;
        }
        sqlite3_finalize(stmt);
    } else if (ok) {
        sqlite3_stmt *stmt = NULL;
        const char *sql =
            "UPDATE tabs "
            "SET title='Appearance', url=?, tab_session_state=NULL "
            "WHERE id=?;";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
            !CGBindText(stmt, 1, CGAppearanceURL) ||
            !CGBindText(stmt, 2, tabID)) {
            ok = NO;
        } else {
            ok = sqlite3_step(stmt) == SQLITE_DONE;
        }
        sqlite3_finalize(stmt);
    }

    if (ok) {
        sqlite3_stmt *stmt = NULL;
        const char *sql =
            "UPDATE tab_state "
            "SET selected_regular_tab_id=?, selected_tab_mode='regular' "
            "WHERE id=1;";
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
            !CGBindText(stmt, 1, tabID)) {
            ok = NO;
        } else {
            ok = sqlite3_step(stmt) == SQLITE_DONE;
        }
        sqlite3_finalize(stmt);
    }

    if (ok) {
        ok = sqlite3_exec(db, "COMMIT TRANSACTION;", NULL, NULL, NULL) == SQLITE_OK;
    } else {
        sqlite3_exec(db, "ROLLBACK TRANSACTION;", NULL, NULL, NULL);
    }

    sqlite3_close(db);

    if (!ok && errorMessage) {
        *errorMessage = @"Could not prepare the Appearance page in ChatGPT.";
    }
    return ok;
}

static void CGTerminateChatGPT(void) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
           RTLD_LAZY);

    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL sharedSelector = NSSelectorFromString(@"sharedService");
    if (!serviceClass || ![serviceClass respondsToSelector:sharedSelector]) return;

    id service = ((id (*)(id, SEL))objc_msgSend)((id)serviceClass, sharedSelector);
    SEL terminateSelector =
        NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
    if (!service || ![service respondsToSelector:terminateSelector]) return;

    ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(
        service,
        terminateSelector,
        CGChatGPTBundleID,
        5,
        NO,
        @"Opening ChatGPT Appearance settings"
    );
}

static BOOL CGLaunchChatGPT(void) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) return NO;

    id workspace =
        ((id (*)(id, SEL))objc_msgSend)((id)workspaceClass, defaultSelector);
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspace || ![workspace respondsToSelector:openSelector]) return NO;

    return ((BOOL (*)(id, SEL, id))objc_msgSend)(
        workspace, openSelector, CGChatGPTBundleID);
}


static id CGCopyPreference(NSString *key) {
    CFPreferencesAppSynchronize(CGPrefsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, CGPrefsDomain);
    return value ? CFBridgingRelease(value) : nil;
}

static void CGSetPreference(NSString *key, id value) {
    CFPreferencesSetAppValue(
        (__bridge CFStringRef)key,
        value ? (__bridge CFPropertyListRef)value : NULL,
        CGPrefsDomain);
    CFPreferencesAppSynchronize(CGPrefsDomain);
}

@interface CGPGuideCell : PSTableCell
@end

@implementation CGPGuideCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)identifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
    if (!self) return nil;

    BOOL refresh = [[specifier propertyForKey:@"tipKind"] isEqualToString:@"refresh"];
    NSString *symbol = refresh ? @"arrow.down.circle" : @"arrow.backward";
    UIColor *accent = refresh ? UIColor.systemBlueColor : UIColor.systemTealColor;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.contentView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.accessibilityTraits = UIAccessibilityTraitStaticText;

    UIView *symbolBox = [UIView new];
    symbolBox.translatesAutoresizingMaskIntoConstraints = NO;
    symbolBox.backgroundColor = [accent colorWithAlphaComponent:0.12];
    symbolBox.layer.cornerRadius = 12.0;
    [self.contentView addSubview:symbolBox];

    UIImageView *symbolView = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:symbol]];
    symbolView.translatesAutoresizingMaskIntoConstraints = NO;
    symbolView.tintColor = accent;
    symbolView.contentMode = UIViewContentModeScaleAspectFit;
    [symbolBox addSubview:symbolView];

    UILabel *heading = [UILabel new];
    heading.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]];
    heading.textColor = UIColor.labelColor;
    heading.adjustsFontForContentSizeCategory = YES;
    heading.text = refresh ? @"Pull to Refresh" : @"Swipe Back";

    UILabel *detail = [UILabel new];
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.adjustsFontForContentSizeCategory = YES;
    detail.numberOfLines = 0;
    detail.text = refresh
        ? @"Drag down on a ChatGPT page to refresh it."
        : @"Swipe right from the left edge to go back one page.";

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[heading, detail]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.alignment = UIStackViewAlignmentFill;
    labels.spacing = 5.0;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:labels];

    [NSLayoutConstraint activateConstraints:@[
        [symbolBox.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
        [symbolBox.widthAnchor constraintEqualToConstant:42.0],
        [symbolBox.heightAnchor constraintEqualToConstant:42.0],
        [symbolBox.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

        [symbolView.widthAnchor constraintEqualToConstant:22.0],
        [symbolView.heightAnchor constraintEqualToConstant:22.0],
        [symbolView.centerXAnchor constraintEqualToAnchor:symbolBox.centerXAnchor],
        [symbolView.centerYAnchor constraintEqualToAnchor:symbolBox.centerYAnchor],

        [labels.leadingAnchor constraintEqualToAnchor:symbolBox.trailingAnchor constant:13.0],
        [labels.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14.0],
        [labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [labels.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:10.0],
        [labels.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-10.0]
    ]];

    self.isAccessibilityElement = YES;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", heading.text, detail.text];
    return self;
}

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    return [self initWithStyle:UITableViewCellStyleDefault
               reuseIdentifier:@"CGPGuideCell"
                     specifier:specifier];
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return 94.0;
}

@end

@interface CGPRootListController : PSListController
@property (nonatomic, strong) UIView *hero;
@property (nonatomic, strong) CAGradientLayer *heroGradient;
@end

@implementation CGPRootListController

- (UITableViewStyle)tableViewStyle {
    return UITableViewStyleInsetGrouped;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.navigationItem.title = @"ChatGPT";

    UITableView *table = self.table;
    if (!table) return;
    table.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(
        0, 0, CGRectGetWidth(table.bounds), 140.0)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *hero = [UIView new];
    hero.frame = CGRectMake(16.0, 16.0,
                            MAX(0.0, CGRectGetWidth(header.bounds) - 32.0),
                            110.0);
    hero.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    hero.layer.cornerRadius = 19.0;
    hero.layer.masksToBounds = YES;
    [header addSubview:hero];
    self.hero = hero;

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[
        (__bridge id)[UIColor colorWithRed:0.10 green:0.13 blue:0.15 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.10 green:0.29 blue:0.25 alpha:1.0].CGColor
    ];
    gradient.startPoint = CGPointMake(0.0, 0.0);
    gradient.endPoint = CGPointMake(1.0, 1.0);
    gradient.frame = hero.bounds;
    [hero.layer insertSublayer:gradient atIndex:0];
    self.heroGradient = gradient;

    UILabel *heading = [UILabel new];
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    heading.text = @"ChatGPT";
    heading.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    heading.textColor = UIColor.whiteColor;
    heading.adjustsFontSizeToFitWidth = YES;
    heading.minimumScaleFactor = 0.84;
    [hero addSubview:heading];

    UILabel *tagline = [UILabel new];
    tagline.translatesAutoresizingMaskIntoConstraints = NO;
    tagline.text = @"Modern ChatGPT. Built for iOS 16 & below.";
    tagline.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    tagline.textColor = [UIColor colorWithWhite:1.0 alpha:0.70];
    [hero addSubview:tagline];

    [NSLayoutConstraint activateConstraints:@[
        [heading.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:24.0],
        [heading.trailingAnchor constraintLessThanOrEqualToAnchor:hero.trailingAnchor constant:-20.0],
        [heading.bottomAnchor constraintEqualToAnchor:hero.centerYAnchor constant:-2.0],

        [tagline.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
        [tagline.trailingAnchor constraintLessThanOrEqualToAnchor:hero.trailingAnchor constant:-20.0],
        [tagline.topAnchor constraintEqualToAnchor:hero.centerYAnchor constant:7.0]
    ]];

    table.tableHeaderView = header;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.heroGradient.frame = self.hero.bounds;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    NSString *identifier = [[self specifierAtIndexPath:indexPath] propertyForKey:@"id"];

    if ([identifier isEqualToString:@"clearHistory"] ||
        [identifier isEqualToString:@"clearCache"]) {
        cell.textLabel.textColor = UIColor.systemBlueColor;
    }

    if ([identifier isEqualToString:@"appearanceLink"]) {
        cell.textLabel.textColor = UIColor.systemPurpleColor;
        cell.imageView.image = [UIImage systemImageNamed:@"paintpalette.fill"];
        cell.imageView.tintColor = UIColor.systemPurpleColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityLabel = @"Open ChatGPT Appearance Settings";
    }

    if ([identifier isEqualToString:@"githubLink"]) {
        cell.textLabel.hidden = YES;
        if ([cell isKindOfClass:PSTableCell.class]) {
            ((PSTableCell *)cell).titleLabel.hidden = YES;
        }

        UIStackView *stack = [cell.contentView viewWithTag:551160];
        if (!stack) {
            stack = [UIStackView new];
            stack.tag = 551160;
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.spacing = 9.0;
            stack.userInteractionEnabled = NO;
            stack.translatesAutoresizingMaskIntoConstraints = NO;

            UIImageView *icon = [[UIImageView alloc] initWithImage:
                [UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"]];
            icon.tintColor = UIColor.systemGreenColor;
            [icon.widthAnchor constraintEqualToConstant:21.0].active = YES;
            [icon.heightAnchor constraintEqualToConstant:20.0].active = YES;

            UILabel *label = [UILabel new];
            label.text = @"View on GitHub";
            label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
            label.textColor = UIColor.systemGreenColor;

            [stack addArrangedSubview:icon];
            [stack addArrangedSubview:label];
            [cell.contentView addSubview:stack];

            [NSLayoutConstraint activateConstraints:@[
                [stack.centerXAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor],
                [stack.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
                [stack.trailingAnchor constraintLessThanOrEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0]
            ]];
        }

        cell.accessibilityLabel = @"View ChatGPT App on GitHub";
    }

    return cell;
}

- (id)readNoHistory:(PSSpecifier *)specifier {
    id value = CGCopyPreference(@"dontSaveLocalHistory");
    return [value isKindOfClass:NSNumber.class] ? value : @NO;
}

- (void)setNoHistory:(id)value specifier:(PSSpecifier *)specifier {
    BOOL enabled = [value boolValue];
    CGSetPreference(@"dontSaveLocalHistory", @(enabled));
    if (enabled) {
        CGSetPreference(@"pendingClearHistory", @YES);
    }
}

- (void)showQueuedAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearHistory:(id)sender {
    CGSetPreference(@"pendingClearHistory", @YES);
    [self showQueuedAlertWithTitle:@"Local History Queued"
                           message:@"Local browsing history will be cleared the next time ChatGPT opens. Your login and conversations will be preserved."];
}

- (void)clearCache:(id)sender {
    CGSetPreference(@"pendingClearCache", @YES);
    [self showQueuedAlertWithTitle:@"Cache Clear Queued"
                           message:@"The local browser cache will be cleared the next time ChatGPT opens. Your login and conversations will be preserved."];
}

- (void)openAppearance:(id)sender {
    CGTerminateChatGPT();

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            NSString *errorMessage = nil;
            if (!CGPrepareAppearanceTab(&errorMessage)) {
                [self showQueuedAlertWithTitle:@"Unable to Open Appearance"
                                       message:errorMessage ?: @"ChatGPT Appearance could not be prepared."];
                return;
            }

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    if (!CGLaunchChatGPT()) {
                        [self showQueuedAlertWithTitle:@"Unable to Open ChatGPT"
                                               message:@"Make sure the ChatGPT app is installed, then try again."];
                    }
                });
        });
}

- (void)openRepository:(id)sender {
    NSURL *url = [NSURL URLWithString:@"https://github.com/551UK/ChatGPT-App-iOS16"];
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

@end
