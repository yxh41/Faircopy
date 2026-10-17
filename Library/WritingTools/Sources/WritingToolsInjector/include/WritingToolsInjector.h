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
