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
#import <unistd.h>

// 3.0.41: the cross-process panel ticket is created with an exclusive
// open(O_CREAT|O_EXCL), which needs <fcntl.h>, and arbitrated on errno.
#import <errno.h>
#import <fcntl.h>

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

/// Number of writing panels currently on screen in this process. Two triggers
/// arriving in the same run loop turn used to both enter presentation; UIKit
/// drops one of them, and the loser's scratch view stayed on the window
/// forever — invisible, but it swallowed every touch on the screen.
///
/// 3.0.34: a COUNT, not a boolean. The old lock was released from
/// `viewDidDisappear`, but UIKit fires that callback when a panel is merely
/// COVERED (another controller presented on top of it) as well as when it is
/// truly dismissed — so the first stack released the lock and every later
/// trigger stacked another panel. Only a true dismissal (verified on the
/// Swift side) decrements now, and the Swift presenters check the count
/// themselves, so the menu path and both external paths share one guard.
static NSInteger __fc_panelPresentationCount = 0;
/// When the count last went 0 → 1, for the stale-count circuit breaker.
static CFAbsoluteTime __fc_panelPresentationLockedAt = 0;

/// Safety valve: if the unlock never arrives (the system tore the panel down
/// without a viewDidDisappear) a plain count would silence external triggers
/// until the app restarts. Only resets when NO panel is on screen, so a panel
/// legitimately left open can never unlock the count.
static const NSTimeInterval kFCStalePresentationLockTimeout = 120;

/// Defined below; the circuit breaker consults the live panel state.
static BOOL FC_IsPanelOnScreen(void);

// The cross-process ticket lives further down (see "Cross-process panel claim").
// Since 3.0.41 its lifetime follows the panel itself, so the presentation lock —
// the one piece of state both the menu path and the external paths share — owns
// its heartbeat: taken when the count goes 0 → 1, dropped when it falls back to 0.
static void FC_TicketHeartbeatStart(void);
static void FC_TicketHeartbeatStopAndDrop(void);

BOOL FC_PanelPresentationIsLocked(void) {
    if (__fc_panelPresentationCount <= 0) { return NO; }
    if (CFAbsoluteTimeGetCurrent() - __fc_panelPresentationLockedAt > kFCStalePresentationLockTimeout
        && !FC_IsPanelOnScreen()) {
        __fc_panelPresentationCount = 0;
        __fc_panelPresentationLockedAt = 0;
        NSLog(@"[Faircopy] presentation lock reset: stale count with no panel on screen");
        // 3.0.41: the ticket must not outlive the panel it guards — a leaked
        // heartbeat would keep every other process silent until it restarts.
        FC_TicketHeartbeatStopAndDrop();
        return NO;
    }
    return YES;
}

void FC_LockPanelPresentation(void) {
    if (__fc_panelPresentationCount == 0) {
        __fc_panelPresentationLockedAt = CFAbsoluteTimeGetCurrent();
        FC_TicketHeartbeatStart();
    }
    __fc_panelPresentationCount++;
}

void FC_UnlockPanelPresentation(void) {
    if (__fc_panelPresentationCount > 0) {
        __fc_panelPresentationCount--;
        if (__fc_panelPresentationCount == 0) {
            __fc_panelPresentationLockedAt = 0;
            FC_TicketHeartbeatStopAndDrop();
        }
    }
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

/// Depth-first over the whole controller graph: presented chains AND child
/// containers. A panel presented from a view controller inside a navigation
/// stack is NOT reachable through presentedViewController alone — that chain
/// only follows presentations, while the field's controller is a child of the
/// navigation controller. The old window-root-only walk therefore missed
/// exactly the panels that used to stack.
static BOOL FC_ViewControllerHasAnyPresented(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 32) { return NO; }
    if (vc.presentedViewController) { return YES; }
    for (UIViewController *child in vc.childViewControllers) {
        if (FC_ViewControllerHasAnyPresented(child, depth + 1)) { return YES; }
    }
    return NO;
}

/// True while a writing panel is actually on screen.
///
/// Deliberately NOT based on the presentation lock: that lock self-expires after
/// 120 s so a wedged trigger cannot block future ones, which makes it useless as
/// a "panel is up" signal (a panel left open for two minutes would look idle).
/// Anchors are only ever created by the standalone path, and that path presents
/// either from a window's root controller or from one of the synthesized
/// stand-in hosts, so those two chains cover every case — walked through child
/// containers as well, see FC_ViewControllerHasAnyPresented.
static BOOL FC_IsPanelOnScreen(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (FC_ViewControllerHasAnyPresented(window.rootViewController, 0)) { return YES; }
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
///
/// 3.0.34 host selection: prefer the focused editing responder's own superview
/// — the same parent controller the external-source path presents from — so a
/// keyword/standalone panel and a context panel can never hang their cards off
/// different controllers (the cross-parent stack). The panel's TEXT SOURCE is
/// still this synthesized view (standalone mode), never the host field: a
/// keyword invocation still ignores the field's selection completely. When no
/// editing responder is on screen, fall back to the foreground key window's
/// root view controller, synthesizing a transparent stand-in host if it has
/// none (otherwise the anchor would have no parentViewController and the
/// presenter would decline).
static UIResponder *FC_MakeStandaloneAnchor(NSString *prefill) {
    UIView *hostView = nil;
    UIWindow *window = nil;

    UIResponder *editing = FC_FindEditingResponder();
    if ([editing isKindOfClass:[UIView class]]) {
        UIView *editingView = (UIView *)editing;
        if (editingView.superview && editingView.window) {
            hostView = editingView.superview;
            window = editingView.window;
        }
    }
    if (!hostView) {
        window = FC_ForegroundKeyWindow();
        if (!window) { return nil; }
        UIViewController *root = window.rootViewController;
        hostView = root.view;
        if (!hostView) {
            UIViewController *standIn = [[UIViewController alloc] init];
            standIn.view.frame = window.bounds;
            standIn.view.backgroundColor = UIColor.clearColor;
            [window addSubview:standIn.view];
            [FC_StandInHosts() addObject:standIn];
            FC_RegisterStandInCleanup();
            hostView = standIn.view;
        }
    }

    // Sweep leftovers first. A previous attempt whose panel never appeared (UIKit
    // dropped the presentation) leaves its scratch view behind, because
    // viewDidDisappear never runs for a controller that was never shown.
    FC_RemoveStaleStandaloneAnchors(window);

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

// MARK: - Cross-process panel claim (3.0.35; heartbeat since 3.0.41)
//
// Everything above is per-process state, which is exactly why 3.0.31–3.0.34
// could not fix the "two panels / needs two taps to dismiss" report: a
// payload-less Darwin broadcast is SYSTEM-WIDE. Every injected process receives
// it — SpringBoard included, whose UIApplication stays `Active` even while an
// app is frontmost — and each then consulted its own private lock, which said
// "nobody is showing a panel" in every single one of them. Two processes, two
// popovers, one screen: the top one swallows the first tap outside, the one
// underneath needs the second.
//
// The fix is an arbitration ticket in the same shared directory the pending
// invocation already uses: the first process to present publishes
// {pid, bundle, at}, and every other process answering the same broadcast sees
// a foreign, fresh ticket and stands down.
//
// 3.0.41 rewrote three parts of that design, because the 3.0.35 ticket was
// still short-lived — it expired 2.5 s after the claim while the panel stayed
// up for as long as the user kept it open. Any broadcast arriving after that
// window (a replayed Darwin notification, an app resuming, a second tap) found
// a STALE ticket, so the process that had not presented yet — SpringBoard above
// all — opened a SECOND panel over the first. That is the "one panel appears,
// another one shows up a moment later" report.
//
//  1. The claim is atomic: `open(O_CREAT|O_EXCL)`. Two processes answering the
//     same broadcast can no longer both read "no ticket" and both present —
//     exactly one create wins, the loser re-reads and stands down. The old
//     read-then-write had a TOCTOU window at exactly the moment that mattered.
//  2. The ticket now has the panel's lifetime: a 1 s heartbeat refreshes `at`
//     while a panel is on screen, and the ticket is deleted the moment the
//     presentation count returns to zero. A live panel is protected for as
//     long as it lives; a closed one blocks nothing.
//  3. The heartbeat self-releases when no panel is on screen any more, so a
//     missed unlock can never silence other processes permanently — the single
//     reason 3.0.35 chose a short TTL in the first place.

/// KEEP IN SYNC with the shared directory used by AIGate's PanelPendingStore.
static NSString *const kFCPanelClaimDirectory =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate";
static NSString *const kFCPanelClaimPath =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_panel_claim.json";

/// How long a claim survives WITHOUT a heartbeat. The heartbeat refreshes it
/// every second while a panel is up, so this only has to cover one missed beat
/// plus SpringBoard's deferral below: an owner that crashed frees the panel
/// ~3.5 s later, and an owner that closed its panel frees it immediately.
static const NSTimeInterval kFCPanelClaimTTL = 3.5;
/// Beat interval while a panel is on screen.
static const NSTimeInterval kFCPanelClaimHeartbeatInterval = 1.0;
/// Grace before a heartbeat may declare the panel gone: dismissal animations
/// tear the controller down over a few hundred milliseconds.
static const NSTimeInterval kFCPanelClaimHeartbeatGrace = 2.5;
/// SpringBoard answers the same broadcast as the caller, but it is the wrong
/// presenter whenever an app is frontmost. It waits this long so the foreground
/// app can claim first — the home screen is the only place SpringBoard wins.
static const NSTimeInterval kFCSpringBoardPresentationDelay = 0.8;

/// Repeating timer that keeps our ticket warm while the panel lives. Only ever
/// touched on the main queue.
static dispatch_source_t gFCPanelClaimHeartbeat = NULL;
/// YES while the heartbeat believes this process owns the ticket.
static BOOL gFCPanelClaimHeartbeatOwnsTicket = NO;
/// When the heartbeat started, for the "panel is gone" grace period.
static CFAbsoluteTime gFCPanelClaimHeartbeatStartAt = 0;

static BOOL FC_IsSpringBoard(void) {
    return [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static NSString *FC_CurrentBundleIdentifier(void) {
    return [NSBundle mainBundle].bundleIdentifier ?: @"";
}

static void FC_EnsurePanelClaimDirectory(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kFCPanelClaimDirectory]) { return; }
    [fm createDirectoryAtPath:kFCPanelClaimDirectory
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
}

/// Reads the ticket without any freshness filter (nil when absent / malformed).
static NSDictionary *FC_ReadPanelClaimRaw(void) {
    NSData *data = [NSData dataWithContentsOfFile:kFCPanelClaimPath];
    if (!data) { return nil; }
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) { return nil; }
    if (![dict[@"at"] isKindOfClass:[NSNumber class]]) { return nil; }
    return dict;
}

static NSTimeInterval FC_PanelClaimAge(NSDictionary *claim) {
    if (!claim) { return CGFLOAT_MAX; }
    return [[NSDate date] timeIntervalSince1970] - [claim[@"at"] doubleValue];
}

/// A ticket is fresh while its owner's heartbeat is still beating. A negative
/// age means the owner's clock ran ahead of ours — treat it as stale-bad and
/// let the arbitration overwrite it, otherwise a skewed clock could pin the
/// panel forever.
static BOOL FC_PanelClaimIsFresh(NSDictionary *claim) {
    if (!claim) { return NO; }
    NSTimeInterval age = FC_PanelClaimAge(claim);
    return age >= 0 && age <= kFCPanelClaimTTL;
}

static BOOL FC_PanelClaimBelongsToThisProcess(NSDictionary *claim) {
    if (!claim) { return NO; }
    return [claim[@"pid"] integerValue] == (NSInteger)getpid();
}

/// The ticket, but only while it is still inside the arbitration window.
static NSDictionary *FC_ReadPanelClaim(void) {
    NSDictionary *claim = FC_ReadPanelClaimRaw();
    return FC_PanelClaimIsFresh(claim) ? claim : nil;
}

/// True when ANOTHER process is holding the panel in a way that must silence
/// this one.
///
/// Three conditions, and each of them exists for a separate failure mode:
///  - the ticket is fresh (the owner's heartbeat is still beating);
///  - it is not ours (our own ticket must never block our own fallback);
///  - its owner reported a FOREGROUND app (`fg`). A panel belongs to the app
///    that is frontmost; once that app is backgrounded its panel is off screen
///    even though the heartbeat keeps running (the controller is still in that
///    app's window tree), so blocking on it would make the panel look dead to
///    the app the user is actually looking at.
static BOOL FC_PanelClaimIsForeign(void) {
    NSDictionary *claim = FC_ReadPanelClaim();
    if (!claim) { return NO; }
    if (FC_PanelClaimBelongsToThisProcess(claim)) { return NO; }
    if (![claim[@"fg"] isKindOfClass:[NSNumber class]]) { return NO; }
    return [claim[@"fg"] boolValue];
}

static NSData *FC_PanelClaimPayload(void) {
    // `applicationState` is main-thread only, and every caller is either a
    // main-queue block or the main-queue heartbeat.
    BOOL foreground = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    NSDictionary *claim = @{
        @"pid": @(getpid()),
        @"bundle": FC_CurrentBundleIdentifier(),
        @"at": @([[NSDate date] timeIntervalSince1970]),
        @"fg": @(foreground),
    };
    return [NSJSONSerialization dataWithJSONObject:claim options:0 error:nil];
}

/// Takes the ticket, atomically. Returns NO only when another LIVE process owns
/// it — the caller then stands down instead of presenting a second panel.
///
/// The claim is an exclusive create, so of two processes answering one
/// broadcast exactly one wins; the loser reads the winner's ticket and backs
/// off. A stale or malformed ticket (crashed owner) is removed and the race is
/// re-run once, which keeps `fcntl` as the only arbiter instead of a
/// read-then-write window.
///
/// Best effort by design: if the shared directory is not writable, the panel
/// still appears — only the cross-process guard is skipped for that trigger.
static BOOL FC_TryClaimPanelTicket(void) {
    FC_EnsurePanelClaimDirectory();
    NSData *payload = FC_PanelClaimPayload();
    if (!payload) { return YES; }
    const char *path = [kFCPanelClaimPath fileSystemRepresentation];
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0644);
        if (fd >= 0) {
            ssize_t written = write(fd, payload.bytes, payload.length);
            close(fd);
            if (written != (ssize_t)payload.length) {
                NSLog(@"[Faircopy] panel claim: short write (%ld of %lu bytes)",
                      (long)written, (unsigned long)payload.length);
            }
            NSLog(@"[Faircopy] panel claim: exclusive create won by %@ (pid %d)",
                  FC_CurrentBundleIdentifier(), (int)getpid());
            return YES;
        }
        if (errno != EEXIST) {
            NSLog(@"[Faircopy] panel claim: open failed (errno %d), presenting unguarded", errno);
            return YES;
        }
        NSDictionary *claim = FC_ReadPanelClaimRaw();
        BOOL fresh = FC_PanelClaimIsFresh(claim);
        BOOL mine = FC_PanelClaimBelongsToThisProcess(claim);
        BOOL ownerForeground =
            [claim[@"fg"] isKindOfClass:[NSNumber class]] && [claim[@"fg"] boolValue];
        if (fresh && !mine) {
            if (ownerForeground) {
                NSString *owner = [claim[@"bundle"] isKindOfClass:[NSString class]]
                    ? claim[@"bundle"] : @"?";
                NSLog(@"[Faircopy] panel claim: %@ (pid %ld) owns the panel, standing down",
                      owner, (long)[claim[@"pid"] integerValue]);
                return NO;
            }
            // Live owner, but its app is backgrounded: its panel is off screen,
            // so this trigger belongs to the app the user is looking at. Take
            // the ticket over in place — deleting it first would let the two
            // heartbeats ping-pong over the same file.
            [payload writeToFile:kFCPanelClaimPath atomically:YES];
            NSLog(@"[Faircopy] panel claim: took the ticket over from a backgrounded owner");
            return YES;
        }
        // Stale, malformed, or our own leftover: clear it and race again.
        [[NSFileManager defaultManager] removeItemAtPath:kFCPanelClaimPath error:nil];
    }
    // Two rounds lost to a racing process — present rather than swallow the
    // user's trigger, the in-process lock still rules out a local duplicate.
    NSLog(@"[Faircopy] panel claim: arbitration raced twice, presenting anyway");
    return YES;
}

/// Drops our ticket after a presentation that never happened, so another
/// process (SpringBoard above all) is still free to show the panel.
static void FC_RelinquishPanelClaim(void) {
    NSDictionary *claim = FC_ReadPanelClaimRaw();
    if (!FC_PanelClaimBelongsToThisProcess(claim)) { return; }
    [[NSFileManager defaultManager] removeItemAtPath:kFCPanelClaimPath error:nil];
}

// MARK: - Ticket heartbeat (3.0.41)

static void FC_TicketHeartbeatStopAndDrop(void);

/// One beat: keep the ticket warm, or give it up when it is no longer ours to
/// keep. Runs on the main queue, once a second, only while a panel is on
/// screen.
static void FC_RefreshPanelClaim(void) {
    if (!gFCPanelClaimHeartbeatOwnsTicket) { return; }
    // A panel torn down without going through the unlock path (host app
    // killed, system dismissal) must not hold the ticket forever: after the
    // grace period, verify a panel is really still there.
    if (CFAbsoluteTimeGetCurrent() - gFCPanelClaimHeartbeatStartAt > kFCPanelClaimHeartbeatGrace
        && !FC_IsPanelOnScreen()) {
        NSLog(@"[Faircopy] panel claim: no panel on screen any more, releasing the ticket");
        FC_TicketHeartbeatStopAndDrop();
        return;
    }
    NSDictionary *claim = FC_ReadPanelClaimRaw();
    if (claim && !FC_PanelClaimBelongsToThisProcess(claim)) {
        // Someone else legitimately took over while we were quiet. Never fight
        // over the file — just stop beating and leave theirs alone.
        NSString *owner = [claim[@"bundle"] isKindOfClass:[NSString class]]
            ? claim[@"bundle"] : @"?";
        NSLog(@"[Faircopy] panel claim: %@ took the ticket over, heartbeat stops", owner);
        gFCPanelClaimHeartbeatOwnsTicket = NO;
        FC_TicketHeartbeatStopAndDrop();
        return;
    }
    if (!claim) {
        // Deleted under us (a takeover removed and lost it): recreate it while
        // our panel is still on screen.
        FC_TryClaimPanelTicket();
        return;
    }
    NSData *payload = FC_PanelClaimPayload();
    if (payload && ![payload writeToFile:kFCPanelClaimPath atomically:YES]) {
        NSLog(@"[Faircopy] panel claim: heartbeat write failed");
    }
}

/// Starts beating for a panel that is about to stay on screen. Called from
/// FC_LockPanelPresentation, i.e. once per 0 → 1 transition of the presentation
/// count, so the menu path and both external paths share one ticket.
static void FC_TicketHeartbeatStart(void) {
    if (gFCPanelClaimHeartbeat) { return; }
    // SpringBoard deliberately does NOT beat. Its `applicationState` is `Active`
    // even while an app is frontmost, so a beating SpringBoard ticket would
    // report `fg` = YES forever and silence every app for as long as a home
    // screen panel stays in its window tree. SpringBoard only needs the ticket
    // to win the single-broadcast race (its own duplicates are already stopped
    // by the in-process count), so the plain TTL covers it — and that keeps a
    // home screen panel from outliving its usefulness.
    if (FC_IsSpringBoard()) {
        NSLog(@"[Faircopy] panel claim: SpringBoard keeps the ticket on TTL only (no heartbeat)");
        return;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    if (!timer) { return; }
    gFCPanelClaimHeartbeatOwnsTicket = YES;
    gFCPanelClaimHeartbeatStartAt = CFAbsoluteTimeGetCurrent();
    uint64_t interval = (uint64_t)(kFCPanelClaimHeartbeatInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval,
                              (uint64_t)(0.25 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{ FC_RefreshPanelClaim(); });
    dispatch_resume(timer);
    gFCPanelClaimHeartbeat = timer;
    NSLog(@"[Faircopy] panel claim: heartbeat started (pid %d, ttl %.1fs)",
          (int)getpid(), kFCPanelClaimTTL);
}

/// Stops beating and removes our ticket, so the next trigger — from this
/// process or any other — is free again. Safe to call when nothing is running.
///
/// Main queue only: the timer, its flags and the ticket file are touched from
/// here and from the heartbeat handler, and the dismiss path that drives it can
/// in principle arrive on another thread.
static void FC_TicketHeartbeatStopAndDrop(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FC_TicketHeartbeatStopAndDrop(); });
        return;
    }
    dispatch_source_t timer = gFCPanelClaimHeartbeat;
    gFCPanelClaimHeartbeat = NULL;  // clear first: the handler must not re-enter
    gFCPanelClaimHeartbeatOwnsTicket = NO;
    if (timer) { dispatch_source_cancel(timer); }
    NSDictionary *claim = FC_ReadPanelClaimRaw();
    if (!FC_PanelClaimBelongsToThisProcess(claim)) { return; }
    [[NSFileManager defaultManager] removeItemAtPath:kFCPanelClaimPath error:nil];
    NSLog(@"[Faircopy] panel claim: released by pid %d", (int)getpid());
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
///
/// 3.0.35: the arbitration ticket is checked and published inside that same
/// block, and SpringBoard — which receives the identical system-wide broadcast —
/// defers one pass so the foreground app claims first.
///
/// 3.0.41: SpringBoard defers EVERY trigger, not just the first one. The old
/// one-shot flag re-armed itself on the deferred pass, so a second broadcast
/// inside the arbitration window skipped the deferral entirely and presented
/// immediately — which is one of the ways a second panel appeared. `deferred`
/// now travels with the call, so a deferred pass is unambiguous and no global
/// flag has to be re-armed (and therefore cannot be re-armed at the wrong time).
static void FC_PresentPanelInPlace(NSString *keyword, BOOL deferred) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (FC_IsSpringBoard() && !deferred) {
            NSLog(@"[Faircopy] SpringBoard defers the panel by %.0f ms so the caller claims it first",
                  kFCSpringBoardPresentationDelay * 1000.0);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(kFCSpringBoardPresentationDelay * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    FC_PresentPanelInPlace(keyword, YES);
                });
            return;
        }
        // 3.0.25: the home screen is now allowed. The tweak's filter is
        // UIKit-wide, so SpringBoard is injected too and receives the trigger;
        // summoning the panel there is useful (it works on the clipboard).
        // The reason it was excluded was the standalone anchor — a full-screen
        // transparent UITextView that would eat every touch if left behind over
        // the icons. That is now covered by FC_SweepIdleStandaloneAnchors, which
        // runs on activation and before every new presentation.
        if (FC_IsSpringBoard()) {
            NSLog(@"[Faircopy] presenting on SpringBoard (home screen)");
        }
        // Clear anything an earlier attempt left behind before making a new one.
        FC_SweepIdleStandaloneAnchors();
        if (FC_PanelPresentationIsLocked()) {
            NSLog(@"[Faircopy] external trigger ignored: a panel is already on screen");
            return;
        }
        // 3.0.35: another PROCESS may own the panel. A payload-less broadcast
        // wakes every injected app and SpringBoard at once, and no in-process
        // lock can see across that boundary — this ticket is the only arbiter.
        // 3.0.41: the claim itself is an exclusive create, so of two processes
        // racing on this exact instant exactly one wins and the loser stands
        // down here instead of stacking a second panel on top.
        if (!FC_TryClaimPanelTicket()) {
            NSLog(@"[Faircopy] external trigger ignored: another process owns the panel");
            return;
        }

        WritingToolsPresenter *presenter = [WritingToolsPresenter sharedInstance];
        BOOL presented = NO;

        if (keyword.length > 0) {
            // Explicit subject: standalone anchor prefilled with the keyword.
            UIResponder *anchor = FC_MakeStandaloneAnchor(keyword);
            if (anchor && [presenter respondsToSelector:@selector(presentToolControllerStandalone:)]) {
                presented = [presenter presentToolControllerStandalone:anchor];
            }
            if (!presented) {
                // The panel never appeared: drop the scratch view we just added,
                // otherwise it stays on screen as an invisible touch blocker.
                UIWindow *keyWindow = FC_ForegroundKeyWindow();
                if (keyWindow) { FC_RemoveStaleStandaloneAnchors(keyWindow); }
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
                UIResponder *anchor = FC_MakeStandaloneAnchor(nil);
                if (anchor && [presenter respondsToSelector:@selector(presentToolControllerStandalone:)]) {
                    presented = [presenter presentToolControllerStandalone:anchor];
                }
                if (!presented) {
                    // The panel never appeared: drop the scratch view we just added,
                    // otherwise it stays on screen as an invisible touch blocker.
                    UIWindow *keyWindow = FC_ForegroundKeyWindow();
                    if (keyWindow) { FC_RemoveStaleStandaloneAnchors(keyWindow); }
                }
            }
        }
        // Only lock on success — a failed attempt must leave the next trigger
        // free to try again.
        if (presented) {
            FC_LockPanelPresentation();
        } else {
            // Nothing reached the screen: hand the arbitration ticket back so
            // another process can still show the panel for this trigger.
            FC_RelinquishPanelClaim();
        }
    });
}

/// Transient `.inactive` states (presentation transitions, Notification Centre,
/// Control Centre, call banners, screenshots, the AIGate bounce-back) used to
/// drop the trigger entirely. Queue it instead and retry until the app is active
/// again, with a bounded wait so a trigger cannot fire minutes later.
static const NSInteger kFCInactiveRetryLimit = 20; // 20 × 250 ms ≈ 5 s
static const NSTimeInterval kFCInactiveRetryDelay = 0.25;

// MARK: - Wake-from-background suppression (3.0.23; hardened 3.0.33)
//
// The external trigger is a Darwin notification, i.e. a system-wide broadcast:
// every injected app receives it, not just the one the user is looking at. The
// observer uses CFNotificationSuspensionBehaviorDeliverImmediately, so an app
// that was suspended when the trigger fired receives it the moment it resumes —
// which is exactly when the user switches to it. Since that app is now active,
// it happily presented a panel the user never asked for there.
//
// 3.0.33: the wake flag is armed by WillEnterForeground (queue:nil, i.e.
// synchronous) instead of DidEnterBackground, for two reasons:
//  1. Darwin CF callbacks are delivered by the runloop source synchronously,
//     while a block observer on [NSOperationQueue mainQueue] is dispatched
//     asynchronously — systematically AFTER the CF callback it races with.
//     That race kept gFCWakeAt stale exactly when a stale re-broadcast
//     landed, which is how the second (home screen) panel survived 3.0.31
//     and 3.0.32.
//  2. WillEnterForeground is posted strictly before DidBecomeActive, so the
//     flag is guaranteed armed before any broadcast can be delivered.
// A claimed invocation (the 3.0.32 handoff file) is exempt from the grace
// window: for it the resume IS the bounce landing, not a stale re-broadcast.

/// Set while this app is transitioning into the foreground; consumed by the
/// next activation to timestamp the resume.
static BOOL gFCEnteringForeground = NO;
/// Timestamp of the last real resume-from-background, 0 when never woken.
static NSTimeInterval gFCWakeAt = 0;
/// How long after a wake a trigger is still considered the stale re-broadcast.
static const NSTimeInterval kFCWakeGrace = 1.5;

// MARK: - Pending panel invocation handoff (3.0.32; broadcast dropped 3.0.33)
//
// AIGate handles `faircopy://panel` by writing the keyword and the bounce
// target into a shared file, then bouncing back to the caller. Before 3.0.33
// it also broadcast the Darwin notification, which carries no payload: every
// injected app presented its own panel from it (the caller's, plus
// SpringBoard's once the user went home) and the `keyword` query item was
// lost. Since 3.0.33 a successful handoff means NO broadcast at all — the
// summon happens when the bounce target itself activates (fallback below).
// The broadcast survives only as the file-write-failure fallback, and this
// process still honours it under the old broadcast semantics.

/// KEEP IN SYNC with PanelPendingStore.path in AIGate/FaircopyApp.swift.
static NSString *const kFCPendingPanelPath =
    @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_panel_pending.json";
/// How long an invocation stays actionable at all: covers the bounce landing
/// (~0.3 s) plus a cold relaunch of the target app.
static const NSTimeInterval kFCPendingInvocationFreshness = 15.0;
/// Tighter window for the activation fallback. Since 3.0.33 AIGate no longer
/// posts a broadcast after a successful handoff, so this fallback is the ONLY
/// summon path left for the bounce target — widened to cover a slow cold
/// relaunch of the target app.
static const NSTimeInterval kFCPendingActivationWindow = 6.0;
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
        // 3.0.33: queue:nil — the block runs synchronously on the posting
        // thread. A block observer on [NSOperationQueue mainQueue] is
        // dispatched asynchronously, i.e. after the runloop pass that also
        // delivers the Darwin CF callback, so the flag it sets was always
        // too late for the suppression below.
        [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull note) {
            gFCEnteringForeground = YES;
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification * _Nonnull note) {
            if (gFCEnteringForeground) {
                gFCWakeAt = [NSDate timeIntervalSinceReferenceDate];
                gFCEnteringForeground = NO;
            }
            // 3.0.32 activation fallback; since 3.0.33 the ONLY summon path:
            // AIGate no longer broadcasts after a successful handoff, so the
            // bounce target must claim the invocation itself the moment it
            // activates. If a fresh invocation is addressed to THIS app and
            // nothing handled it yet, present now. Non-target apps and stale
            // files stay silent.
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
            FC_PresentPanelInPlace(keyword, NO);
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

    // No pending invocation — either a third-party tweak's plain notify_post,
    // or AIGate's 3.0.33 handoff-failure fallback broadcast. Original
    // broadcast semantics: context-driven path, no keyword.
    NSLog(@"[Faircopy] external trigger: bare broadcast, no pending invocation");
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
        // 3.0.41: the menu path is user-initiated inside THIS process, but it can
        // still collide with a panel another process is showing (SpringBoard, or
        // the app the user just came from) and the in-process count cannot see
        // across that boundary. Arbitrate on the same ticket the external paths
        // use, so the menu can never be the second of two panels either.
        if (FC_PanelClaimIsForeign()) {
            NSDictionary *claim = FC_ReadPanelClaim();
            NSString *owner = [claim[@"bundle"] isKindOfClass:[NSString class]]
                ? claim[@"bundle"] : @"?";
            NSLog(@"[Faircopy] menu trigger ignored: another process owns the panel (%@ pid %ld)",
                  owner, (long)[claim[@"pid"] integerValue]);
            return;
        }
        FC_TryClaimPanelTicket();
        WritingToolsPresenter *presenter = [WritingToolsPresenter sharedInstance];
        [presenter presentToolController:self];
        // Nothing reached the screen (ineligible responder, no parent controller,
        // or a panel was already up): hand the ticket back, otherwise an external
        // trigger would be blocked for the whole TTL.
        if (!FC_PanelPresentationIsLocked()) {
            FC_RelinquishPanelClaim();
        }
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
