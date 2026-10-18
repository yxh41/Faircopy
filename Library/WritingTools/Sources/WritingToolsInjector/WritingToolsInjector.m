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
/// lets stale anchors be swept without keeping a reference to them; since 3.0.31
/// they are also tracked in a zeroing-weak registry (see FC_AnchorRegistry).
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
/// tagged children: `removeFromSuperview` mutates the list, so the removal loop
/// re-scans `subviews` each pass instead of iterating a snapshot.
static NSInteger FC_RemoveStaleStandaloneAnchors(UIView *root) {
    if (!root) { return 0; }
    for (UIView *subview in root.subviews) {
        if (subview.tag != kFCStandaloneAnchorTag) {
            FC_RemoveStaleStandaloneAnchors(subview);
        }
    }
    NSInteger removed = 0;
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
        removed++;
    }
    return removed;
}

// Defined further down; the sweeper needs to know about synthesized hosts.
static NSMutableArray<UIViewController *> *FC_StandInHosts(void);

/// True while a writing panel is actually on screen.
///
/// Deliberately NOT based on the presentation lock: that lock self-expires after
/// 120 s so a wedged trigger cannot block future ones, which makes it useless as
/// a "panel is up" signal (a panel left open for two minutes would look idle).
/// Anchors are only ever created by the standalone path, and that path presents
/// either from a window's root controller or from one of the synthesized
/// stand-in hosts, so those two chains cover every case.
static BOOL FC_IsPanelOnScreen(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            UIViewController *vc = window.rootViewController;
            NSInteger depth = 0;
            while (vc.presentedViewController && depth < 16) {
                vc = vc.presentedViewController;
                depth++;
            }
            if (depth > 0) { return YES; }
        }
    }
    for (UIViewController *host in FC_StandInHosts()) {
        if (host.presentedViewController) { return YES; }
    }
    return NO;
}

/// Weak registry of every standalone anchor this process has synthesized.
///
/// 3.0.25 swept by DFS-ing every window's whole subview tree on each
/// activation, which walks deep view hierarchies (WeChat / Taobao) on every
/// foreground and risks frame drops. Anchors are only ever created by
/// FC_MakeStandaloneAnchor, so a zeroing weak table gives identical coverage
/// in O(anchors): an anchor whose superview released it (panel dismissed)
/// disappears from the table by itself. The table itself is a strong static;
/// members stay weak.
static NSHashTable<UIView *> *FC_AnchorRegistry(void) {
    static NSHashTable *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        registry = [NSHashTable weakObjectsHashTable];
    });
    return registry;
}

/// Removes leftover scratch anchors — but only while no panel is on screen,
/// because a live panel's anchor is its text source and must stay.
///
/// Safety net for the standalone path: the anchor is a full-screen transparent
/// UITextView, and a presentation that never completes never runs its
/// `viewDidDisappear`, so the view would otherwise stay in the window forever
/// swallowing every touch. Sweeping on activation means a stuck layer clears
/// itself the next time the user comes back to that app (worst case once the
/// 120 s presentation lock expires).
///
/// 3.0.31: walks the weak anchor registry instead of the window trees — see
/// FC_AnchorRegistry. The tag-based FC_RemoveStaleStandaloneAnchors is still
/// used on the presentation path (specific window, user-triggered), where the
/// tree walk is cheap and the registry may legitimately hold detached entries.
static NSInteger FC_SweepIdleStandaloneAnchors(void) {
    // A live panel's anchor is its text source — never touch it.
    if (FC_PanelPresentationIsLocked() || FC_IsPanelOnScreen()) { return 0; }
    NSInteger removed = 0;
    // Snapshot holds strong references to the live anchors only (detached ones
    // were released by their superview and are already gone from the table).
    NSArray<UIView *> *snapshot = [FC_AnchorRegistry() allObjects];
    for (UIView *anchor in snapshot) {
        if (![anchor isKindOfClass:[UIView class]]) { continue; }
        if (anchor.superview) {
            [anchor removeFromSuperview];
            removed++;
        }
    }
    if (removed > 0) {
        NSLog(@"[Faircopy] swept %ld idle standalone anchor(s)", (long)removed);
    }
    return removed;
}

/// Sweeps leftover anchors whenever the app becomes active again — exactly the
/// moment the user returns to a home screen that a stuck anchor would cover.
static void FC_RegisterIdleAnchorSweep(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
            FC_SweepIdleStandaloneAnchors();
        }];
    });
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
///
/// 3.0.31: `prefill` (from `faircopy://panel?keyword=…`) replaces the clipboard
/// as the anchor's content, so a keyword invocation never reads or waits on the
/// pasteboard. Passing nil keeps the original clipboard behavior.
static UIResponder *FC_MakeStandaloneAnchor(UIWindow *window, NSString *prefill) {
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

    NSString *content = prefill.length > 0 ? prefill : [UIPasteboard generalPasteboard].string;
    if (content.length == 0) {
        // Keep the anchor non-empty: an empty selection makes the presenter's
        // TextProxy ineligible, which triggers its "unavailable" shake. A single
        // space keeps it eligible (no shake) while still summoning the panel.
        content = @" ";
    }
    if (prefill.length > 0) {
        NSLog(@"[Faircopy] standalone anchor prefilled with keyword (%lu chars)",
              (unsigned long)prefill.length);
    }
    textView.text = content;
    UITextPosition *start = textView.beginningOfDocument;
    UITextPosition *end = textView.endOfDocument;
    textView.selectedTextRange = [textView textRangeFromPosition:start toPosition:end];
    // 3.0.31: track the anchor so the idle sweeper can find it without walking
    // the window trees. The table is zeroing-weak: once the panel's dismiss
    // path removes the view from its superview, the entry clears by itself.
    [FC_AnchorRegistry() addObject:textView];
    return textView;
}

/// Present the writing panel in the current (foreground) app, with no app
/// switch and no bounce through the AIGate companion app. This is the shared
/// in-place path used by both the `faircopy://panel` URL interception hook and
/// the Darwin-notification callback. The actual presentation is dispatched to
/// the main queue, so this is safe to call from any thread.
///
/// `keyword` (3.0.31, from `faircopy://panel?keyword=…`) is an explicit subject:
/// when present, the panel goes straight to the standalone anchor prefilled
/// with that keyword — it never reads the clipboard and never attaches to the
/// focused text input (whose selection would otherwise silently win). Passing
/// nil keeps the original context-driven behavior.
///
/// The whole attempt runs inside one main-queue block, so the lock check and the
/// lock acquisition cannot interleave with a second trigger.
static void FC_PresentPanelInPlace(NSString *keyword) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 3.0.25: the home screen is now allowed. The tweak's filter is
        // UIKit-wide, so SpringBoard is injected too and receives the trigger;
        // summoning the panel there is useful (it works on the clipboard).
        // The reason it was excluded was the standalone anchor — a full-screen
        // transparent UITextView that would eat every touch if left behind over
        // the icons. That is now covered by FC_SweepIdleStandaloneAnchors, which
        // runs on activation and before every new presentation.
        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"[Faircopy] presenting on SpringBoard (home screen)");
        }
        // Clear anything an earlier attempt left behind before making a new one.
        FC_SweepIdleStandaloneAnchors();
        if (FC_PanelPresentationIsLocked()) {
            NSLog(@"[Faircopy] external trigger ignored: a panel is already on screen");
            return;
        }

        WritingToolsPresenter *presenter = [WritingToolsPresenter sharedInstance];
        BOOL presented = NO;

        if (keyword.length > 0) {
            // Explicit subject: standalone anchor prefilled with the keyword.
            UIWindow *keyWindow = FC_ForegroundKeyWindow();
            UIResponder *anchor = keyWindow ? FC_MakeStandaloneAnchor(keyWindow, keyword) : nil;
            if (anchor && [presenter respondsToSelector:@selector(presentToolControllerStandalone:)]) {
                presented = [presenter presentToolControllerStandalone:anchor];
            }
            if (!presented && keyWindow) {
                // The panel never appeared: drop the scratch view we just added,
                // otherwise it stays on screen as an invisible touch blocker.
                FC_RemoveStaleStandaloneAnchors(keyWindow);
            }
        } else {
            // Prefer the real, focused text input so "accept" writes the result
            // back into the field. The external-source entry never shakes: it
            // returns NO when it cannot present (no parent controller, or the
            // selection is ineligible even after a select-all), and we then fall
            // back to a standalone scratch view so the panel always appears.
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
                UIResponder *anchor = keyWindow ? FC_MakeStandaloneAnchor(keyWindow, nil) : nil;
                if (anchor && [presenter respondsToSelector:@selector(presentToolControllerStandalone:)]) {
                    presented = [presenter presentToolControllerStandalone:anchor];
                }
                if (!presented && keyWindow) {
                    // The panel never appeared: drop the scratch view we just added,
                    // otherwise it stays on screen as an invisible touch blocker.
                    FC_RemoveStaleStandaloneAnchors(keyWindow);
                }
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

// MARK: - Wake-from-background suppression (3.0.23)
//
// The external trigger is a Darwin notification, i.e. a system-wide broadcast:
// every injected app receives it, not just the one the user is looking at. The
// observer uses CFNotificationSuspensionBehaviorDeliverImmediately, so an app
// that was suspended when the trigger fired receives it the moment it resumes —
// which is exactly when the user switches to it. Since that app is now active,
// it happily presented a panel the user never asked for there.
//
// Only a resume that follows a real backgrounding counts as a "wake". A
// foreground app that briefly goes .inactive during a presentation transition
// never left the foreground, so it is NOT a wake and keeps the 3.0.21 retry
// behaviour (its trigger still lands).

/// Set when this app entered the background; consumed by the next activation.
static BOOL gFCWasBackgrounded = NO;
/// Timestamp of the last real resume-from-background, 0 when never woken.
static NSTimeInterval gFCWakeAt = 0;
/// How long after a wake a trigger is still considered the stale re-broadcast.
static const NSTimeInterval kFCWakeGrace = 1.5;

// MARK: - Pending panel invocation handoff (3.0.32)
//
// AIGate handles `faircopy://panel` by bouncing back to the caller and then
// broadcasting the Darwin notification — but that broadcast carries no
// payload, so before 3.0.32 every injected app presented its own panel from
// it (the caller's, plus SpringBoard's once the user went home) and the
// `keyword` query item was lost. AIGate now writes the keyword and the bounce
// target into a shared file first; this process acts on the broadcast only
// when the invocation is addressed to it.

/// KEEP IN SYNC with PanelPendingStore.path in AIGate/FaircopyApp.swift.
static NSString *const kFCPendingPanelPath =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_panel_pending.json";
/// How long an invocation stays actionable at all: covers the bounce landing
/// (~0.3 s) plus a cold relaunch of the target app.
static const NSTimeInterval kFCPendingInvocationFreshness = 15.0;
/// Tighter window for the activation fallback, which only exists to cover a
/// bounce that lands after the broadcast was already delivered or dropped.
static const NSTimeInterval kFCPendingActivationWindow = 4.0;
/// `at` of the invocation this process already handled — the broadcast and the
/// activation fallback must not both present for one invocation.
static NSTimeInterval gFCHandledPendingInvocationAt = -1.0;

/// Reads the pending invocation, or nil when absent, malformed, or stale.
static NSDictionary *FC_ReadPendingPanelInvocation(void) {
    NSData *data = [NSData dataWithContentsOfFile:kFCPendingPanelPath];
    if (!data) { return nil; }
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) { return nil; }
    if (![dict[@"at"] isKindOfClass:[NSNumber class]]) { return nil; }
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - [dict[@"at"] doubleValue];
    if (age > kFCPendingInvocationFreshness) { return nil; }
    return dict;
}

/// True when the invocation is addressed to THIS app (or carries no target,
/// i.e. a plain third-party `notify_post` — old broadcast semantics).
static BOOL FC_PendingPanelInvocationTargetsMe(NSDictionary *invocation) {
    NSString *target = [invocation[@"target"] isKindOfClass:[NSString class]]
        ? invocation[@"target"] : @"";
    if (target.length == 0) { return YES; }
    NSString *mine = [NSBundle mainBundle].bundleIdentifier ?: @"";
    return [target isEqualToString:mine];
}

static NSString *FC_PendingPanelInvocationKeyword(NSDictionary *invocation) {
    NSString *keyword = [invocation[@"keyword"] isKindOfClass:[NSString class]]
        ? invocation[@"keyword"] : @"";
    return keyword.length > 0 ? keyword : nil;
}

/// Marks the invocation as handled by this process and returns its keyword
/// (nil when the invocation carries none — the caller then runs the original
/// context-driven path).
static NSString *FC_ClaimPendingPanelInvocation(NSDictionary *invocation) {
    gFCHandledPendingInvocationAt = [invocation[@"at"] doubleValue];
    NSString *keyword = FC_PendingPanelInvocationKeyword(invocation);
    if (keyword) {
        NSLog(@"[Faircopy] panel invocation: keyword handoff accepted (%lu chars)",
              (unsigned long)keyword.length);
    }
    return keyword;
}

static void FC_PresentPanelWhenUsable(NSInteger attempt, NSString *keyword, BOOL claimedInvocation);

static void FC_TrackWakeFromBackground(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
            gFCWasBackgrounded = YES;
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
            if (gFCWasBackgrounded) {
                gFCWakeAt = [NSDate timeIntervalSinceReferenceDate];
                gFCWasBackgrounded = NO;
            }
            // 3.0.32 activation fallback: the bounce may bring this app to the
            // foreground after the broadcast was already delivered (target
            // relaunching) or dropped (still background at +1.0 s). If a fresh
            // invocation is addressed to THIS app and nothing handled it yet,
            // present now. Non-target apps and stale files stay silent.
            NSDictionary *invocation = FC_ReadPendingPanelInvocation();
            if (!invocation) { return; }
            if (!FC_PendingPanelInvocationTargetsMe(invocation)) { return; }
            NSTimeInterval at = [invocation[@"at"] doubleValue];
            if (at == gFCHandledPendingInvocationAt) { return; }
            if (([[NSDate date] timeIntervalSince1970] - at) > kFCPendingActivationWindow) { return; }
            NSString *keyword = FC_ClaimPendingPanelInvocation(invocation);
            NSLog(@"[Faircopy] panel invocation: presenting on activation (target match)");
            FC_PresentPanelWhenUsable(0, keyword, YES);
        }];
    });
}

static void FC_PresentPanelWhenUsable(NSInteger attempt, NSString *keyword, BOOL claimedInvocation) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplicationState state = [UIApplication sharedApplication].applicationState;
        if (state == UIApplicationStateActive) {
            // A trigger delivered just after a resume is the stale re-broadcast
            // of a trigger the user issued in a different app — drop it instead
            // of popping a panel in whichever app they switched to. A claimed
            // invocation is exempt: the resume IS the bounce landing, and
            // dropping it here is exactly the race that lost caller panels.
            if (!claimedInvocation &&
                gFCWakeAt > 0 &&
                ([NSDate timeIntervalSinceReferenceDate] - gFCWakeAt) < kFCWakeGrace) {
                NSLog(@"[Faircopy] external trigger dropped: stale re-broadcast right after resume");
                return;
            }
            FC_PresentPanelInPlace(keyword);
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
                FC_PresentPanelWhenUsable(attempt + 1, keyword, claimedInvocation);
            });
    });
}

static void FC_DarwinNotifyCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                     const void *object, CFDictionaryRef userInfo)
{
    // AIGate posts this broadcast itself; it must never present a panel over
    // its own (hidden) windows. The in-place URL interception already excludes
    // AIGate — the broadcast path now does too.
    if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"wiki.qaq.AIGate"]) { return; }

    // 3.0.32: the broadcast itself carries no payload. AIGate hands the keyword
    // and the intended target through the shared pending-invocation file; when
    // the invocation is addressed to another app (SpringBoard above all), this
    // process must stay out of it — that broadcast is what produced the second
    // panel on the home screen.
    NSDictionary *invocation = FC_ReadPendingPanelInvocation();
    if (invocation) {
        if (!FC_PendingPanelInvocationTargetsMe(invocation)) {
            NSString *target = [invocation[@"target"] isKindOfClass:[NSString class]]
                ? invocation[@"target"] : @"";
            NSLog(@"[Faircopy] external trigger dropped: not the caller (target %@)", target);
            return;
        }
        if ([invocation[@"at"] doubleValue] == gFCHandledPendingInvocationAt) {
            NSLog(@"[Faircopy] external trigger dropped: invocation already handled");
            return;
        }
        // Background at broadcast time: leave the invocation UNCLAIMED so the
        // activation fallback can still present once the bounce lands.
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
            NSLog(@"[Faircopy] external trigger dropped: app is in background");
            return;
        }
        NSString *keyword = FC_ClaimPendingPanelInvocation(invocation);
        FC_PresentPanelWhenUsable(0, keyword, YES);
        return;
    }

    // No pending invocation (e.g. a third-party tweak's plain notify_post):
    // original broadcast semantics, context-driven path, no keyword.
    FC_PresentPanelWhenUsable(0, nil, NO);
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

/// Extracts a percent-decoded `keyword` query item from a `faircopy://panel`
/// URL, e.g. `faircopy://panel?keyword=hello%20world` → `hello world`.
/// Returns nil when absent, blank, or the URL is malformed — the caller then
/// behaves exactly as before 3.0.31 (context-driven, clipboard fallback).
static NSString *FC_KeywordFromPanelURL(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                             resolvingAgainstBaseURL:NO];
    if (!components) { return nil; }
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"keyword"]) { continue; }
        NSString *value = item.value ?: @"";
        value = [value stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (value.length > 0) { return value; }
    }
    return nil;
}

static BOOL (*old_UIApplication_openURL_)(UIApplication *, SEL, NSURL *);
static void (*old_UIApplication_openURL_options_completion_)(UIApplication *, SEL, NSURL *, NSDictionary *, void (^)(BOOL));

static BOOL new_UIApplication_openURL_(UIApplication *self, SEL _cmd, NSURL *url) {
    if (FC_ShouldPresentFaircopyPanelInPlace(url)) {
        // 3.0.14: present the panel in place, no app switch to AIGate.
        NSString *keyword = FC_KeywordFromPanelURL(url);
        if (keyword.length > 0) {
            // 3.0.31: keyword invocation — the panel's subject is the keyword,
            // so it never touches the clipboard nor the focused text input.
            NSLog(@"[Faircopy] faircopy://panel intercepted in-process, presenting in place with keyword (%lu chars)",
                  (unsigned long)keyword.length);
        } else {
            NSLog(@"[Faircopy] faircopy://panel intercepted in-process, presenting in place");
        }
        FC_PresentPanelWhenUsable(0, keyword, NO);
        return YES;
    }
    return old_UIApplication_openURL_(self, _cmd, url);
}

static void new_UIApplication_openURL_options_completion_(UIApplication *self, SEL _cmd, NSURL *url,
                                                         NSDictionary *options, void (^completion)(BOOL))
{
    if (FC_ShouldPresentFaircopyPanelInPlace(url)) {
        // 3.0.14: present the panel in place, no app switch to AIGate.
        NSString *keyword = FC_KeywordFromPanelURL(url);
        if (keyword.length > 0) {
            NSLog(@"[Faircopy] faircopy://panel intercepted in-process, presenting in place with keyword (%lu chars)",
                  (unsigned long)keyword.length);
        } else {
            NSLog(@"[Faircopy] faircopy://panel intercepted in-process, presenting in place");
        }
        FC_PresentPanelWhenUsable(0, keyword, NO);
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

    // Suppress the re-broadcast of a trigger to apps that resume later; see
    // FC_PresentPanelWhenUsable.
    FC_TrackWakeFromBackground();

    // Clear leftover scratch anchors on activation, so a stuck full-screen
    // transparent view can never permanently block the host app (or the home
    // screen). See FC_SweepIdleStandaloneAnchors.
    FC_RegisterIdleAnchorSweep();

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
