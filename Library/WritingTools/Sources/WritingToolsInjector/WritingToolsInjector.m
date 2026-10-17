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

/// Transparent host view controllers synthesized when the foreground window
/// has no root view controller. They are removed once the panel they presented
/// is dismissed and the app becomes active again. Kept alive here so the
/// cleanup observer can find them.
static NSMutableArray<UIViewController *> *FC_StandInHosts(void) {
    static NSMutableArray *arr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ arr = [NSMutableArray new]; });
    return arr;
}

static void FC_RegisterStandInCleanup(void) {
    static dispatch_once_t once;
    static id observer = nil;
    dispatch_once(&once, ^{
        observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
            for (UIViewController *host in [FC_StandInHosts() copy]) {
                if (host.presentedViewController == nil) {
                    [host.view removeFromSuperview];
                    [FC_StandInHosts() removeObject:host];
                }
            }
        }];
    });
}

/// Build the scratch text view used when the foreground app has no editable
/// text to attach to. It is prefilled with the clipboard (if any) so the
/// copy → invoke → rewrite → copy-back flow needs no typing, and removed by the
/// controller when the panel is dismissed.
///
/// 3.0.15: the anchor is now fully transparent — no dark backing — so the panel
/// floats over the host app instead of painting a full-screen black background.
/// If the key window has no root view controller we synthesize a transparent
/// stand-in controller (so the anchor still has a `parentViewController`;
/// otherwise the presenter would fall back to a "shake" unavailability signal).
static UIResponder *FC_MakeStandaloneAnchor(UIWindow *window) {
    if (!window) { return nil; }

    UIViewController *host = window.rootViewController;
    UIView *hostView = host.view;

    if (!host || !hostView) {
        UIViewController *standIn = [[UIViewController alloc] init];
        standIn.view.frame = window.bounds;
        standIn.view.backgroundColor = UIColor.clearColor;
        [window addSubview:standIn.view];
        [FC_StandInHosts() addObject:standIn];
        FC_RegisterStandInCleanup();
        host = standIn;
        hostView = standIn.view;
    }

    UITextView *textView = [[UITextView alloc] initWithFrame:hostView.bounds];
    textView.backgroundColor = UIColor.clearColor;
    textView.textColor = UIColor.clearColor;
    textView.layer.cornerRadius = 0;
    textView.clipsToBounds = NO;
    textView.editable = YES;
    textView.selectable = YES;
    textView.autocorrectionType = UITextAutocorrectionTypeNo;
    textView.spellCheckingType = UITextSpellCheckingTypeNo;
    textView.textContainerInset = UIEdgeInsetsZero;
    textView.contentInset = UIEdgeInsetsZero;
    textView.textContainer.lineFragmentPadding = 0;
    [hostView addSubview:textView];

    // NOTE: ObjC has no UIPasteboard.general (Swift-only overlay name);
    // the Objective-C API is +generalPasteboard.
    NSString *clipboard = [UIPasteboard generalPasteboard].string;
    if (clipboard.length == 0) {
        // Keep the anchor non-empty: an empty selection makes the presenter's
        // TextProxy ineligible, which triggers its "unavailable" shake. A single
        // space keeps it eligible (no shake) while still summoning the panel.
        clipboard = @" ";
    }
    textView.text = clipboard;
    UITextPosition *start = textView.beginningOfDocument;
    UITextPosition *end = textView.endOfDocument;
    textView.selectedTextRange = [textView textRangeFromPosition:start toPosition:end];
    return textView;
}

/// Present the writing panel in the current (foreground) app, with no app
/// switch and no bounce through the AIGate companion app. This is the shared
/// in-place path used by both the `faircopy://panel` URL interception hook and
/// the Darwin-notification callback. The actual presentation is dispatched to
/// the main queue, so this is safe to call from any thread.
static void FC_PresentPanelInPlace(void) {
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
        // from anywhere — home screen, Settings, Safari without focus. The
        // anchor is fully transparent, so no dark backing is shown.
        UIWindow *keyWindow = FC_ForegroundKeyWindow();
        UIResponder *anchor = keyWindow ? FC_MakeStandaloneAnchor(keyWindow) : nil;
        if (anchor) {
            // Present via the standalone path; the anchor always has a
            // parentViewController (synthesized stand-in host when needed), so
            // the presenter never falls back to a "shake" unavailability signal.
            // If the selector were somehow missing we fail silently — never shake.
            if ([presenter respondsToSelector:@selector(presentToolControllerStandalone:)]) {
                [presenter presentToolControllerStandalone:anchor];
            }
            return;
        }
        // No foreground window to anchor into: there is nothing to present into,
        // so do NOT signal "unavailable" (that would shake the host). Fail
        // silently instead.
    });
}

static void FC_DarwinNotifyCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                     const void *object, CFDictionaryRef userInfo)
{
    // Only the foreground app should react; backgrounded apps cannot present.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    FC_PresentPanelInPlace();
}

// MARK: - In-place faircopy://panel interception

/// True when `faircopy://panel` should be presented directly in the calling
/// app instead of being handed to the OS (which would foreground AIGate and
/// bounce back). We only intercept when ALL of:
///  - the scheme is `faircopy` and the host is `panel`;
///  - we are NOT running inside AIGate itself (AIGate owns its own URL
///    handling — e.g. `spawn`, and the fallback bounce from sources our hook
///    does not observe, such as Safari's address bar);
///  - the current app has a foreground key window to present into.
static BOOL FC_ShouldPresentFaircopyPanelInPlace(NSURL *url) {
    if (![url.scheme isEqualToString:@"faircopy"]) { return NO; }
    if (![url.host isEqualToString:@"panel"]) { return NO; }
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"wiki.qaq.AIGate"]) { return NO; }
    if (!FC_ForegroundKeyWindow()) { return NO; }
    return YES;
}

static BOOL (*old_UIApplication_openURL_)(UIApplication *, SEL, NSURL *);
static void (*old_UIApplication_openURL_options_completion_)(UIApplication *, SEL, NSURL *, NSDictionary *, void (^)(BOOL));

static BOOL new_UIApplication_openURL_(UIApplication *self, SEL _cmd, NSURL *url) {
    if (FC_ShouldPresentFaircopyPanelInPlace(url)) {
        // 3.0.14: present the panel in place, no app switch to AIGate.
        NSLog(@"[Faircopy] faircopy://panel intercepted in-process, presenting in place");
        FC_PresentPanelInPlace();
        return YES;
    }
    return old_UIApplication_openURL_(self, _cmd, url);
}

static void new_UIApplication_openURL_options_completion_(UIApplication *self, SEL _cmd, NSURL *url,
                                                         NSDictionary *options, void (^completion)(BOOL))
{
    if (FC_ShouldPresentFaircopyPanelInPlace(url)) {
        // 3.0.14: present the panel in place, no app switch to AIGate.
        NSLog(@"[Faircopy] faircopy://panel intercepted in-process, presenting in place");
        FC_PresentPanelInPlace();
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
        }
        return;
    }
    old_UIApplication_openURL_options_completion_(self, _cmd, url, options, completion);
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

    // In-place `faircopy://panel` interception: when any injected app opens the
    // URL, present the panel right there instead of letting the OS foreground
    // AIGate and bounce back. See FC_ShouldPresentFaircopyPanelInPlace.
    Class uiAppCls = NSClassFromString(@"UIApplication");
    if (class_getInstanceMethod(uiAppCls, @selector(openURL:))) {
        WTHookMessageExecute(uiAppCls, @selector(openURL:),
                             (IMP)new_UIApplication_openURL_, (IMP *)&old_UIApplication_openURL_);
    }
    if (class_getInstanceMethod(uiAppCls, @selector(openURL:options:completionHandler:))) {
        WTHookMessageExecute(uiAppCls, @selector(openURL:options:completionHandler:),
                             (IMP)new_UIApplication_openURL_options_completion_,
                             (IMP *)&old_UIApplication_openURL_options_completion_);
    }

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
