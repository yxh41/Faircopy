//
//  WritingToolsPresenter.h
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/19.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class WritingToolsPresenter;

@interface WritingToolsPresenter : NSObject
+ (instancetype)sharedInstance;
- (NSString *)writingToolMenuName;
- (void)presentToolController:(UIResponder *)responder;
- (void)presentToolControllerFromExternalSource:(UIResponder *)responder;
- (void)presentUnavailable:(UIResponder *)responder;
@end

NS_ASSUME_NONNULL_END
