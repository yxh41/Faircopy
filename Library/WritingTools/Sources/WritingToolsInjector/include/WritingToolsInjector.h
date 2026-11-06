//
//  WritingToolsInjector.h
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/19.
//

#import <UIKit/UIKit.h>

#define kWritingToolSelectorName "_WT_OpenTools_3cf98861"
#define kWritingToolSelectorSignature "v@:"

/// Darwin notification other tweaks / shortcuts can post to summon the writing
/// panel from outside the system edit menu (e.g. custom text menus that our
/// menu injection does not cover):
///
///     #import <notify/notify.h>
///     notify_post("wiki.qaq.faircopy.present");
///
/// Equivalent URL scheme: opening `faircopy://panel` from any injected app
/// (Safari, a Shortcuts "Open URL" action, a launcher) now presents the panel
/// in place in that app — no app switch to AIGate and no bounce. AIGate still
/// handles the URL as a fallback when it is opened from a source our in-process
/// hook does not observe (e.g. Safari's address bar). The tweak intercepts the
/// URL inside the calling app and calls FC_PresentPanelInPlace() directly.
#define kFCExternalPresentNotification "wiki.qaq.faircopy.present"

/// 3.0.119: posted by whichever process actually put a card on screen.
///
/// The external trigger above is a bare broadcast: it reaches EVERY injected
/// process, SpringBoard included, and nobody in that set is the "right" one by
/// construction. A third-party caller (VCamX's drawer posts the name verbatim,
/// Kayoko posts it for text over 1000 characters) therefore produces two cards:
/// the foreground app answers immediately, and SpringBoard — which defers 0.8 s
/// so the caller can claim the cross-process ticket first — answers too whenever
/// that ticket is missing, unreadable, or still marked `fg = false`.
///
/// This notification is the missing half of that handshake. It carries no file
/// dependency at all, which is the point: `notify_post` needs no sandbox
/// permission, so it works even when the shared preferences directory does not.
#define kFCPanelPresentedNotification "wiki.qaq.faircopy.presented"

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("hidden")))
@interface WritingToolsInjector : NSObject
@end

/// The most recent text input that became first responder for editing.
/// Recorded by the `_responderForEditing` hook in Faircopy.xm; used by the
/// external trigger to know which field the panel should operate on.
/// Declared extern "C" because Logos compiles .xm files as Objective-C++,
/// which would otherwise mangle these symbols and break linking.
#ifdef __cplusplus
extern "C" {
#endif

UIResponder *_Nullable FC_LastEditingResponder(void);
void FC_SetLastEditingResponder(UIResponder *_Nullable responder);

/// Guards against two panels on screen at once. Opening two panels in the same
/// run loop turn makes UIKit drop the second one, and the loser's scratch text
/// view stays on the window forever — an invisible full-screen view that
/// swallows every touch.
///
/// 3.0.34: a COUNT of live panels, not a boolean. UIKit fires
/// `viewDidDisappear` when a panel is merely covered as well as when it is
/// dismissed, so the old boolean released the lock for a panel that was still
/// on screen — the root cause of stacked panels. The Swift presenters
/// (`presentToolController:` and `presentCenteredCard`) check the count
/// themselves before presenting, so the menu path and both external paths
/// share one guard; the panel controller decrements only on a true dismissal.
///
/// 3.0.41: the count also drives the cross-process ticket's heartbeat — 0 → 1
/// starts it, 0 on the way down deletes the ticket. That is what lets a live
/// panel keep other processes (SpringBoard above all) silent for its whole
/// lifetime instead of a fixed 2.5 s window, which is how a late duplicate
/// broadcast used to produce a second panel.
BOOL FC_PanelPresentationIsLocked(void);
void FC_LockPanelPresentation(void);
void FC_UnlockPanelPresentation(void);

/// 3.0.120: the "Q bounce" entrance flag, as last reported by AIGate.
///
/// roothide redirects `/var/mobile/Library/Preferences` per process, so a panel
/// running inside a sandboxed app read its own empty copy of
/// `faircopy_panel_animation.json` and silently fell back to `false` — no
/// animation in WeChat/QQ while Settings showed one. The gateway at
/// 127.0.0.1:5540 is reached from this very process for every model request, so
/// it is the one channel known to survive; AIGate owns the file and answers.
///
/// `known` is set to NO until a background fetch lands, so the caller can fall
/// back to reading the file exactly as before.
BOOL FC_PanelSpringEntrance(BOOL *_Nullable known);

#ifdef __cplusplus
}
#endif

__attribute__((visibility("hidden")))
@interface WKContentView : UIView <UITextInput>
- (BOOL)isFocusingElement;
- (void)selectAllForWebView:(nullable id)sender;
- (void)replaceFoundTextInRange:(UITextRange *)range inDocument:(nullable id)document withText:(NSString *)replacementText;
- (void)accessibilityRetrieveSpeakSelectionContent;
@end

__attribute__((visibility("hidden")))
@interface WKContentView (FaircopyPrivate)
@property (nonatomic, strong, nullable) NSString *fc_selectedText;
@property (nonatomic, strong, nullable) dispatch_semaphore_t fc_isGettingSelectedTextSemaphore;
- (void)accessibilitySpeakSelectionSetContent:(NSString *)string;
@end

NS_ASSUME_NONNULL_END
