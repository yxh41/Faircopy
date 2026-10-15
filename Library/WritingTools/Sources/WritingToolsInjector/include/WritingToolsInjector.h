//
//  WritingToolsInjector.h
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/19.
//

#import <UIKit/UIKit.h>

#define kWritingToolSelectorName "_WT_OpenTools_3cf98861"
#define kWritingToolSelectorSignature "v@:"

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("hidden")))
@interface WritingToolsInjector : NSObject
@end

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
