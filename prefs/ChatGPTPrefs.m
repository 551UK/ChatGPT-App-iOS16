#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

@interface CGPRootListController : PSListController
@end

@implementation CGPRootListController

- (UITableViewStyle)tableViewStyle {
    return UITableViewStyleInsetGrouped;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ChatGPT";

    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    UIImage *iconImage = [UIImage imageNamed:@"icon"
                                    inBundle:bundle
               compatibleWithTraitCollection:nil];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 128)];

    UIImageView *icon = [[UIImageView alloc] initWithImage:iconImage];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.layer.cornerRadius = 14.0;
    icon.layer.masksToBounds = YES;
    [header addSubview:icon];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"ChatGPT";
    title.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    [header addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"iOS 16";
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    subtitle.textColor = UIColor.secondaryLabelColor;
    [header addSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20.0],
        [icon.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:58.0],
        [icon.heightAnchor constraintEqualToConstant:58.0],

        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:16.0],
        [title.bottomAnchor constraintEqualToAnchor:header.centerYAnchor constant:-1.0],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-16.0],

        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:header.centerYAnchor constant:6.0],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-16.0]
    ]];

    self.table.tableHeaderView = header;
}

- (PSSpecifier *)tipSpecifierWithName:(NSString *)name symbol:(NSString *)symbol {
    PSSpecifier *specifier =
        [PSSpecifier preferenceSpecifierNamed:name
                                       target:self
                                          set:nil
                                          get:nil
                                       detail:nil
                                         cell:PSStaticTextCell
                                         edit:nil];

    UIImage *image = [UIImage systemImageNamed:symbol];
    if (image) [specifier setProperty:image forKey:@"iconImage"];
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *refreshGroup =
        [PSSpecifier groupSpecifierWithName:@"REFRESH"];
    [refreshGroup setProperty:
        @"Drag down on a ChatGPT page to refresh it."
                      forKey:@"footerText"];
    [items addObject:refreshGroup];
    [items addObject:[self tipSpecifierWithName:@"Pull to Refresh"
                                         symbol:@"arrow.down.circle.fill"]];

    PSSpecifier *backGroup =
        [PSSpecifier groupSpecifierWithName:@"NAVIGATION"];
    [backGroup setProperty:
        @"Swipe right from the left edge of the screen to go back one page."
                   forKey:@"footerText"];
    [items addObject:backGroup];
    [items addObject:[self tipSpecifierWithName:@"Swipe Back"
                                         symbol:@"arrow.backward.circle.fill"]];

    PSSpecifier *aboutGroup =
        [PSSpecifier groupSpecifierWithName:@"ABOUT"];
    [aboutGroup setProperty:@"Made by 551UK" forKey:@"footerText"];
    [items addObject:aboutGroup];

    _specifiers = [items copy];
    return _specifiers;
}

@end
