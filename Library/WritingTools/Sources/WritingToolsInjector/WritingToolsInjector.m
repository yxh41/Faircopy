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

// MARK: - Presentation bookkeeping

/// Tag for the scratch text view synthesized by FC_MakeStandaloneAnchor. Tagging
/// lets stale anchors be swept without keeping a reference to them (this file is
/// compiled without ARC, so a raw static pointer could dangle).
static NSInteger const kFCStandaloneAnchorTag = 0xF0C0;

/// True while a panel is on screen. Two triggers arriving in the same run loop
/// turn used to both enter presentation; UIKit drops one of them, and the loser's
/// scratch view stayed on the window forever — invisible, but it swallowed every
/// touch on the screen. Locked by the injector, released by the panel controller
/// on dismissal.
static BOOL __fc_panelPresentationLocked = NO;
static CFAbsoluteTime __fc_panelPresentationLockedAt = 0;

/// Safety valve: if the unlock never arrives (the system tore the panel down
/// without a viewDidDisappear) a plain boolean would silence external triggers
/// until the app restarts.
static const NSTimeInterval kFCStalePresentationLockTimeout = 120;

BOOL FC_PanelPresentationIsLocked(void) {
    if (!__fc_panelPresentationLocked) { return NO; }
    if (CFAbsoluteTimeGetCurrent() - __fc_panelPresentationLockedAt > kFCStalePresentationLockTimeout) {
        __fc_panelPresentationLocked = NO;
        __fc_panelPresentationLockedAt = 0;
        return NO;
    }
    return YES;
}

void FC_LockPanelPresentation(void) {
    __fc_panelPresentationLocked = YES;
    __fc_panelPresentationLockedAt = CFAbsoluteTimeGetCurrent();
}

void FC_UnlockPanelPresentation(void) {
    __fc_panelPresentationLocked = NO;
    __fc_panelPresentationLockedAt = 0;
}

/// Removes every leftover scratch anchor under `root`.
///
/// Depth-first over the live subview list, then a restart-on-removal loop for the
/// tagged children: `removeFromSuperview` mutates the list, and this file is MRC
/// (no ARC flag in Package.swift), so taking a `copy` snapshot would leak.
static void FC_RemoveStaleStandaloneAnchors(UIView *root) {
    if (!root) { return; }
    for (UIView *subview in root.subviews) {
        if (subview.tag != kFCStandaloneAnchorTag) {
            FC_RemoveStaleStandaloneAnchors(subview);
        }
    }
    for (NSInteger guard = 0; guard < 1024; guard++) {
        UIView *victim = nil;
        for (UIView *subview in root.subviews) {
            if (subview.tag == kFCStandaloneAnchorTag) {
                victim = subview;
                break;
            }
        }
        if (!victim) { break; }
        [victim removeFromSuperview];
    }
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

    // Sweep leftovers first. A previous attempt whose panel never appeared (UIKit
    // dropped the presentation) leaves its scratch view behind, because
    // viewDidDisappear never runs for a controller that was never shown.
    FC_RemoveStaleStandaloneAnchors(window);

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
    textView.tag = kFCStandaloneAnchorTag;
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
///
/// The whole attempt runs inside one main-queue block, so the lock check and the
/// lock acquisition cannot interleave with a second trigger.
static void FC_PresentPanelInPlace(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // The tweak's filter is UIKit-wide, so SpringBoard is injected too. A
        // panel floating over the home screen is never wanted, and its scratch
        // view would sit on top of the icons.
        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            return;
        }
        if (FC_PanelPresentationIsLocked()) {
            NSLog(@"[Faircopy] external trigger ignored: a panel is already on screen");
            return;
        }

        WritingToolsPresenter *presenter = [WritingToolsPresenter sharedInstance];
        // Prefer the real, focused text input so "accept" writes the result
        // back into the field. The external-source entry never shakes: it
        // returns NO when it cannot present (no parent controller, or the
        // selection is ineligible even after a select-all), and we then fall
        // back to a standalone scratch view so the panel always appears.
        BOOL presented = NO;
        UIResponder *responder = FC_FindEditingResponder();
        if (responder && [presenter respondsToSelector:@selector(presentToolControllerFromExternalSource:)]) {
            presented = [presenter presentToolControllerFromExternalSource:responder];
        }
        if (!presented) {
            // No usable focused responder (or the external path declined): fall
            // back to a standalone scratch view prefilled with the clipboard. The
            // anchor is fully transparent and always has a parentViewController,
            // so the standalone path presents without shaking.
            UIWindow *keyWindow = FC_ForegroundKeyWindow();
            UIResponder *anchor = keyWindow ? FC_MakeStandaloneAnchor(keyWindow) : nil;
            if (anchor && [presenter respondsToSelector:@selector(presentToolControllerStandalone:)]) {
                presented = [presenter presentToolControllerStandalone:anchor];
            }
            if (!presented && keyWindow) {
                // The panel never appeared: drop the scratch view we just added,
                // otherwise it stays on screen as an invisible touch blocker.
                FC_RemoveStaleStandaloneAnchors(keyWindow);
            }
        }
        // Only lock on success — a failed attempt must leave the next trigger
        // free to try again.
        if (presented) {
            FC_LockPanelPresentation();
        }
    });
}

/// Transient `.inactive` states (presentation transitions, Notification Centre,
/// Control Centre, call banners, screenshots, the AIGate bounce-back) used to
/// drop the trigger entirely. Queue it instead and retry until the app is active
/// again, with a bounded wait so a trigger cannot fire minutes later.
static const NSInteger kFCInactiveRetryLimit = 20; // 20 × 250 ms ≈ 5 s
static const NSTimeInterval kFCInactiveRetryDelay = 0.25;

static void FC_PresentPanelWhenUsable(NSInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplicationState state = [UIApplication sharedApplication].applicationState;
        if (state == UIApplicationStateActive) {
            FC_PresentPanelInPlace();
            return;
        }
        if (state == UIApplicationStateBackground) {
            NSLog(@"[Faircopy] external trigger dropped: app is in background");
            return;
        }
        if (attempt >= kFCInactiveRetryLimit) {
            NSLog(@"[Faircopy] external trigger dropped: stayed inactive for %.1fs",
                  (double)attempt * kFCInactiveRetryDelay);
            return;
        }
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFCInactiveRetryDelay * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                FC_PresentPanelWhenUsable(attempt + 1);
            });
    });
}

static void FC_DarwinNotifyCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                     const void *object, CFDictionaryRef userInfo)
{
    FC_PresentPanelWhenUsable(0);
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
        FC_PresentPanelWhenUsable(0);
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
        FC_PresentPanelWhenUsable(0);
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
