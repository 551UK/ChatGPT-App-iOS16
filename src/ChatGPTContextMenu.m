// Remove Reynard's unsupported browser-tab actions from ChatGPT link previews.
// v0.51 extends the known-good 0.50 shell without changing its navigation,
// Gecko engine, ChatGPT page, or the Copy Link / Share Link actions.
//
// Reynard 0.19.0 uses UIContextMenuConfiguration(identifier:previewProvider:
// actionProvider:) in LinkPreviewMenu.swift. Swift bridges that convenience
// initializer to UIKit's +configurationWithIdentifier:previewProvider:actionProvider:.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

typedef UIContextMenuConfiguration *(*CGMenuFactoryIMP)(
    id, SEL, id<NSCopying>, UIContextMenuContentPreviewProvider,
    UIContextMenuActionProvider);

static CGMenuFactoryIMP CGOriginalMenuFactory = NULL;

static BOOL CGMenuTitleIs(UIMenuElement *element, NSString *english) {
    NSString *localized = [[NSBundle mainBundle] localizedStringForKey:english
                                                               value:english table:nil];
    return [element.title isEqualToString:english] ||
           [element.title isEqualToString:localized];
}

static BOOL CGMenuContainsTitle(UIMenu *menu, NSString *title) {
    for (UIMenuElement *element in menu.children) {
        if (CGMenuTitleIs(element, title)) return YES;
        if ([element isKindOfClass:UIMenu.class] &&
            CGMenuContainsTitle((UIMenu *)element, title)) return YES;
    }
    return NO;
}

static UIMenu *CGMenuWithoutBrowserTabs(UIMenu *menu) {
    NSMutableArray<UIMenuElement *> *retained = [NSMutableArray array];
    BOOL changed = NO;
    for (UIMenuElement *element in menu.children) {
        if ([element isKindOfClass:UIAction.class] &&
            (CGMenuTitleIs(element, @"Open Link in New Tab") ||
             CGMenuTitleIs(element, @"Open Link in New Private Tab"))) {
            changed = YES;
            continue;
        }
        if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *child = (UIMenu *)element;
            UIMenu *filteredChild = CGMenuWithoutBrowserTabs(child);
            if (filteredChild != child) changed = YES;
            if (filteredChild.children.count == 0) {
                changed = YES; // Also remove the now-empty inline tab section.
                continue;
            }
            [retained addObject:filteredChild];
        } else {
            [retained addObject:element];
        }
    }
    return changed ? [menu menuByReplacingChildren:retained] : menu;
}

static UIContextMenuConfiguration *CGChatGPTContextMenuFactory(
    id receiver, SEL selector, id<NSCopying> identifier,
    UIContextMenuContentPreviewProvider previewProvider,
    UIContextMenuActionProvider actionProvider) {

    if (!CGOriginalMenuFactory) return nil;
    if (!actionProvider) {
        return CGOriginalMenuFactory(receiver, selector, identifier,
                                     previewProvider, actionProvider);
    }

    UIContextMenuActionProvider originalProvider = [actionProvider copy];
    UIContextMenuActionProvider filteredProvider =
        ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            UIMenu *menu = originalProvider(suggestedActions);
            if (![menu isKindOfClass:UIMenu.class]) return menu;

            // Scope this to Reynard's link-preview menu: both standard link
            // actions must exist. Don't touch image, text-selection, or web
            // app context menus with unrelated entries.
            if (!CGMenuContainsTitle(menu, @"Copy Link") ||
                !CGMenuContainsTitle(menu, @"Share Link")) return menu;

            return CGMenuWithoutBrowserTabs(menu);
        };
    return CGOriginalMenuFactory(receiver, selector, identifier,
                                 previewProvider, filteredProvider);
}

__attribute__((constructor))
static void CGInstallChatGPTContextMenuFilter(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier]
                  isEqualToString:@"com.551uk.chatgptios16"]) return;

        Method factory = class_getClassMethod(UIContextMenuConfiguration.class,
            @selector(configurationWithIdentifier:previewProvider:actionProvider:));
        if (!factory) {
            NSLog(@"[ChatGPTGecko] Link context-menu factory unavailable");
            return;
        }

        CGOriginalMenuFactory = (CGMenuFactoryIMP)method_setImplementation(
            factory, (IMP)CGChatGPTContextMenuFactory);
        NSLog(@"[ChatGPTGecko] Unsupported browser-tab context actions filtered");
    }
}
