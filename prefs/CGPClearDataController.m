#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

extern void CGTerminateChatGPT(void);

static CFStringRef const CGDataPrefsDomain = CFSTR("com.551uk.chatgpt.settings");

// Must match the bitmask interpreted by ChatGPTDataMaintenance.m.
typedef NS_OPTIONS(NSUInteger, CGClearCategory) {
    CGClearCategoryHistory     = 1 << 0,
    CGClearCategoryCache       = 1 << 1,
    CGClearCategoryPermissions = 1 << 2,
    CGClearCategoryDownloads   = 1 << 3,
    CGClearCategoryTabs        = 1 << 4
};

@interface CGPClearDataController : UITableViewController
@property (nonatomic, strong) NSArray<UISwitch *> *categorySwitches;
@end

@implementation CGPClearDataController

static NSArray<NSString *> *CGCategoryNames(void) {
    return @[@"Browsing History",
             @"Cached Images and Files",
             @"Website Permissions",
             @"Downloads",
             @"Open Tabs"];
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Clear App Data";
        NSMutableArray<UISwitch *> *items = [NSMutableArray array];
        for (NSUInteger i = 0; i < 5; i++) {
            UISwitch *toggle = [UISwitch new];
            toggle.on = YES;
            toggle.onTintColor = UIColor.systemGreenColor;
            [items addObject:toggle];
        }
        self.categorySwitches = items;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 58.0;
    self.tableView.estimatedRowHeight = 58.0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 5 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"SELECT DATA TO REMOVE" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Cookies, website data and saved sign-in sessions are never cleared. "
               @"Website permissions will need to be granted again when requested.";
    }
    return @"Selected data is removed when ChatGPT next starts. "
           @"The app will be closed safely after confirmation. This cannot be undone.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc]
                            initWithStyle:UITableViewCellStyleDefault
                            reuseIdentifier:nil];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;

    if (indexPath.section == 0) {
        cell.textLabel.text = CGCategoryNames()[(NSUInteger)indexPath.row];
        cell.accessoryView = self.categorySwitches[(NSUInteger)indexPath.row];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityHint = @"Double tap to select or deselect this cleanup category.";
    } else {
        cell.textLabel.text = @"Clear Selected Data";
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        cell.accessibilityHint = @"Review the selected categories before clearing.";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        UISwitch *toggle = self.categorySwitches[(NSUInteger)indexPath.row];
        [toggle setOn:!toggle.isOn animated:YES];
        return;
    }
    [self confirmClearSelectedData];
}

- (NSUInteger)selectedMask {
    NSUInteger mask = 0;
    for (NSUInteger i = 0; i < self.categorySwitches.count; i++) {
        if (self.categorySwitches[i].isOn) mask |= (1UL << i);
    }
    return mask;
}

- (void)confirmClearSelectedData {
    NSUInteger mask = [self selectedMask];
    if (!mask) {
        UIAlertController *nothing = [UIAlertController
            alertControllerWithTitle:@"Nothing Selected"
                             message:@"Select at least one type of data to clear."
                      preferredStyle:UIAlertControllerStyleAlert];
        [nothing addAction:[UIAlertAction actionWithTitle:@"OK"
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
        [self presentViewController:nothing animated:YES completion:nil];
        return;
    }

    NSMutableArray<NSString *> *chosen = [NSMutableArray array];
    for (NSUInteger i = 0; i < 5; i++) {
        if (mask & (1UL << i)) [chosen addObject:CGCategoryNames()[i]];
    }
    NSString *summary = [NSString stringWithFormat:
        @"The following data will be removed:\n\n• %@\n\n"
         @"Your ChatGPT login, cookies and website data will remain saved. "
         @"Downloads selected here are permanently deleted. "
         @"ChatGPT will close and apply the changes on its next launch.",
         [chosen componentsJoinedByString:@"\n• "]];

    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Clear Selected Data?"
                         message:summary
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Clear Data"
                                                style:UIAlertActionStyleDestructive
                                              handler:^(__unused UIAlertAction *action) {
        [weakSelf queueSelectedMask:mask];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)queueSelectedMask:(NSUInteger)mask {
    CFPreferencesAppSynchronize(CGDataPrefsDomain);
    CFPropertyListRef oldValue = CFPreferencesCopyAppValue(
        CFSTR("pendingClearCategories"), CGDataPrefsDomain);
    NSUInteger oldMask = 0;
    if (oldValue) {
        if (CFGetTypeID(oldValue) == CFNumberGetTypeID()) {
            long long number = 0;
            if (CFNumberGetValue((CFNumberRef)oldValue, kCFNumberLongLongType, &number)
                && number > 0) oldMask = (NSUInteger)number;
        }
        CFRelease(oldValue);
    }
    int savedMask = (int)(oldMask | mask);
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &savedMask);
    CFPreferencesSetAppValue(CFSTR("pendingClearCategories"), value, CGDataPrefsDomain);
    CFRelease(value);

    if (!CFPreferencesAppSynchronize(CGDataPrefsDomain)) {
        UIAlertController *error = [UIAlertController
            alertControllerWithTitle:@"Unable to Save Request"
                             message:@"The cleanup request could not be saved. No data was removed."
                      preferredStyle:UIAlertControllerStyleAlert];
        [error addAction:[UIAlertAction actionWithTitle:@"OK"
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];
        [self presentViewController:error animated:YES completion:nil];
        return;
    }

    CGTerminateChatGPT();

    UIAlertController *done = [UIAlertController
        alertControllerWithTitle:@"Cleanup Scheduled"
                         message:@"Reopen ChatGPT to clear the selected data. "
                                 @"Cookies and saved login sessions are excluded."
                  preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"Done"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

@end
