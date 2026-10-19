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
