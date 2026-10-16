//
//  WritingToolsInjector.m
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

#import "WritingToolsInjector.h"
#import "WritingToolsPresenter.h"
#import "WritingToolsMenu.h"

#import "PrivateClasses.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// NOTE: no <notify/notify.h> here — the iOS SDK does not ship it, and the
// Darwin notification observer below only needs CoreFoundation
// (CFNotificationCenter*), which UIKit already links.

// MARK: - External Trigger (Darwin notification)

/// The most recent text input that became first responder for editing.
/// Only ever touched on the main thread.
static UIResponder *__fc_lastEditingResponder = nil;

UIResponder *FC_LastEditingResponder(void) {
    return __fc_lastEditingResponder;
}

void FC_SetLastEditingResponder(UIResponder *responder) {
    __fc_lastEditingResponder = responder;
}

static UIView *FC_FindFirstResponderInView(UIView *view) {
    if ([view isFirstResponder] && [view conformsToProtocol:@protocol(UITextInput)]) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *found = FC_FindFirstResponderInView(subview);
        if (found) { return found; }
    }
    return nil;
}

/// Best-effort target for an externally triggered panel: the last editing
/// responder if its view is still on screen, otherwise the current first
/// responder of the foreground key window.
static UIResponder *FC_FindEditingResponder(void) {
    UIResponder *last = FC_LastEditingResponder();
    if ([last isKindOfClass:[UIView class]] && [(UIView *)last window]) {
        return last;
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) { continue; }
        for (UIWindow *window in windowScene.windows) {
            if (!window.isKeyWindow) { continue; }
            UIView *found = FC_FindFirstResponderInView(window);
            if (found) { return found; }
        }
    }
    return nil;
}

static UIWindow *FC_ForegroundKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) { continue; }
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) { return window; }
        }
    }
    return nil;
}

/// Build the scratch text view used when the foreground app has no editable
/// text to attach to. It is prefilled with the clipboard (if any) so the
/// copy → invoke → rewrite → copy-back flow needs no typing, and removed by
/// the controller when the panel is dismissed.
static UITextView *FC_CreateStandaloneTextView(UIWindow *window) {
    UIViewController *rootController = window.rootViewController;
    if (!rootController) { return nil; }

    UITextView *textView = [[UITextView alloc] initWithFrame:rootController.view.bounds];
    textView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    textView.textColor = UIColor.whiteColor;
    textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    textView.layer.cornerRadius = 20;
    textView.clipsToBounds = YES;
    textView.alwaysBounceVertical = YES;
    textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    // Keep the first lines below the centered card area.
    textView.textContainerInset = UIEdgeInsetsMake(
        rootController.view.bounds.size.height * 0.30, 20, 24, 20
    );
    [rootController.view addSubview:textView];

    NSString *clipboard = UIPasteboard.general.string;
    if (clipboard.length > 0) {
        textView.text = clipboard;
        UITextPosition *start = textView.beginningOfDocument;
        UITextPosition *end = textView.endOfDocument;
        textView.selectedTextRange = [textView textRangeFromPosition:start toPosition:end];
    }
    return textView;
}

static void FC_DarwinNotifyCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                     const void *object, CFDictionaryRef userInfo)
{
    // Only the foreground app should react; backgrounded apps cannot present.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        WritingToolsPresenter *presenter = [WritingToolsPresenter sharedInstance];
        UIResponder *responder = FC_FindEditingResponder();
        if (responder) {
            if ([presenter respondsToSelector:@selector(presentToolControllerFromExternalSource:)]) {
                [presenter presentToolControllerFromExternalSource:responder];
            }
            return;
        }
        // No editable text on screen: fall back to a standalone scratch view
        // (prefilled with the clipboard) so the panel can still be summoned
        // from anywhere — home screen, Settings, Safari without focus.
        UIWindow *keyWindow = FC_ForegroundKeyWindow();
        UITextView *standalone = keyWindow ? FC_CreateStandaloneTextView(keyWindow) : nil;
        if (standalone) {
            if ([presenter respondsToSelector:@selector(presentToolControllerStandalone:)]) {
                [presenter presentToolControllerStandalone:standalone];
            } else {
                [standalone removeFromSuperview];
                [presenter presentUnavailable:keyWindow];
            }
            return;
        }
        // Nothing to anchor to at all: fail loudly instead of silently.
        if (keyWindow) {
            [presenter presentUnavailable:keyWindow];
        }
    });
}

// MARK: - UIResponder

static void add_UIResponder_openWriteTools(id self, SEL _cmd) {
    dispatch_async(dispatch_get_main_queue(), ^{
        WritingToolsPresenter *presenter = [WritingToolsPresenter sharedInstance];
        [presenter presentToolController:self];
    });
}

// MARK: - _UIEditMenuPresentation @ iOS 16+

static void (*old__UIEditMenuPresentation_displayMenu_configuration_)(id, SEL, UIMenu *, id);
static void new__UIEditMenuPresentation_displayMenu_configuration_(id self, SEL _cmd, UIMenu *menu, id configuration) {
    NSMutableArray *build = [NSMutableArray new];
    for (id item in [menu children]) {
        if (WT_MenuItem_IsWritingTool(item)) { continue; }
        if (![item isKindOfClass:[UIMenu class]]) {
            [build addObject:item];
            continue;
        }
        UIMenu *submenu = item;
        if (![submenu.identifier isEqualToString:WT_AppleMenuIdentifier()]) {
            [build addObject:submenu];
            continue;
        }
        NSMutableArray *rebuildAppleEditMenu = [submenu.children mutableCopy];
        [rebuildAppleEditMenu addObject:WT_MenuItem_UICommand()];
        UIMenu *rebuildAppleMenu = [submenu menuByReplacingChildren:rebuildAppleEditMenu];
        [build addObject:rebuildAppleMenu];
    }
    UIMenu *newMenu = [menu menuByReplacingChildren:build];
    old__UIEditMenuPresentation_displayMenu_configuration_(self, _cmd, newMenu, configuration);
}

// MARK: - UICalloutBar @ iOS 15+

static void (*old_UICalloutBar_setExtraItems_)(UICalloutBar *, SEL, NSArray<UIMenuItem *> *);
static void new_UICalloutBar_setExtraItems_(UICalloutBar *self, SEL _cmd, NSArray<UIMenuItem *> *items) {
    NSMutableArray<UIMenuItem *> *newItems = [NSMutableArray arrayWithCapacity:items.count];
    for (UIMenuItem *item in items) {
        NSString *selectorName = NSStringFromSelector(item.action);
        if ([selectorName isEqualToString:@kWritingToolSelectorName]) {
            item.action = NSSelectorFromString(@"__dummy__");
        }
        [newItems addObject:item];
    }
    old_UICalloutBar_setExtraItems_(self, _cmd, [newItems copy]);
}

static void (*old_UICalloutBar_updateAvailableButtons)(UICalloutBar *, SEL);
static void new_UICalloutBar_updateAvailableButtons(UICalloutBar *self, SEL _cmd) {
    Class cbsbdCls = NSClassFromString(@"_UICalloutBarSystemButtonDescription");
    if (!cbsbdCls || ![cbsbdCls respondsToSelector:@selector(buttonDescriptionWithTitle:action:type:)]) {
        return old_UICalloutBar_updateAvailableButtons(self, _cmd);
    }

    UIMenuItem *FaircopyItem = WT_MenuItem();
    _UICalloutBarSystemButtonDescription *buttonDescription = [cbsbdCls
                                                               buttonDescriptionWithTitle:FaircopyItem.title
                                                               action:NSSelectorFromString(@kWritingToolSelectorName)
                                                               type:1];

    if (!buttonDescription) { return old_UICalloutBar_updateAvailableButtons(self, _cmd); }

    Ivar msbd = class_getInstanceVariable(object_getClass(self), "m_systemButtonDescriptions");
    if (!msbd) { return old_UICalloutBar_updateAvailableButtons(self, _cmd); }

    NSMutableArray *buttonDescriptions = object_getIvar(self, msbd);
    for (_UICalloutBarSystemButtonDescription *description in buttonDescriptions) {
        if (!description.action) { continue; }
        NSString *selectorName = NSStringFromSelector(description.action);
        if ([selectorName isEqualToString:NSStringFromSelector(buttonDescription.action)]) {
            return old_UICalloutBar_updateAvailableButtons(self, _cmd);
        }
    }

    NSInteger insertIndex = NSNotFound;
    NSInteger currentIndex = 0;
    for (_UICalloutBarSystemButtonDescription *description in buttonDescriptions) {
        if (!description.action) { continue; }
        if ([NSStringFromSelector(description.action) hasPrefix:@"_"]) {
            insertIndex = currentIndex;
            break;
        }
        currentIndex++;
    }

    if (insertIndex == 0) { return old_UICalloutBar_updateAvailableButtons(self, _cmd); }

    if (insertIndex == NSNotFound) {
        [buttonDescriptions addObject:buttonDescription];
    } else {
        [buttonDescriptions insertObject:buttonDescription atIndex:insertIndex];
    }

    return old_UICalloutBar_updateAvailableButtons(self, _cmd);
}

// MARK: - HOOK

__attribute__((always_inline)) void WTHookMessageExecute(Class cls, SEL selName, IMP replaced, IMP *orig) {
    Method origMethod = class_getInstanceMethod(cls, selName);
    if (!origMethod && orig == 0) {
        return;
    }
    *orig = method_setImplementation(origMethod, replaced);
}

__attribute__((always_inline)) BOOL WTAddMessageExecute(Class cls, SEL selName, IMP impl, NSString *sign) {
    if (cls == nil || selName == nil || impl == nil || sign == nil) {
        return;
    }
    return class_addMethod(cls, selName, impl, sign.UTF8String);
}

// MARK: - WritingToolsInjector

@implementation WritingToolsInjector

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self _initializeWritingTool];
    });
}

+ (void)_initializeWritingTool {
    WTAddMessageExecute(NSClassFromString(@"UIResponder"), NSSelectorFromString(@kWritingToolSelectorName),
                        (IMP)add_UIResponder_openWriteTools, @"v@:");

    // External trigger: other tweaks (or the faircopy://panel URL, forwarded
    // by AIGate) post this Darwin notification to summon the panel in places
    // the system edit menu injection does not reach.
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        FC_DarwinNotifyCallback,
        CFSTR(kFCExternalPresentNotification),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    if (@available(iOS 16, *)) {
        Class targetCls = NSClassFromString(@"_UIEditMenuContentPresentation");
        if (!targetCls) {
            targetCls = NSClassFromString(@"_UIEditMenuPresentation");
        }
        WTHookMessageExecute(targetCls, @selector(displayMenu:configuration:),
                             (IMP)new__UIEditMenuPresentation_displayMenu_configuration_,
                             (IMP *)&old__UIEditMenuPresentation_displayMenu_configuration_);
    } else if (@available(iOS 15, *)) {
        WTHookMessageExecute(NSClassFromString(@"UICalloutBar"), @selector(setExtraItems:),
                             (IMP)new_UICalloutBar_setExtraItems_, (IMP *)&old_UICalloutBar_setExtraItems_);
        WTHookMessageExecute(NSClassFromString(@"UICalloutBar"), @selector(updateAvailableButtons),
                             (IMP)new_UICalloutBar_updateAvailableButtons,
                             (IMP *)&old_UICalloutBar_updateAvailableButtons);
    }
}

@end
