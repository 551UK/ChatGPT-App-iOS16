#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>

static CFStringRef const CGPrefsDomain = CFSTR("com.551uk.chatgpt.settings");

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

- (void)openRepository:(id)sender {
    NSURL *url = [NSURL URLWithString:@"https://github.com/551UK/ChatGPT-App-iOS16"];
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

@end
