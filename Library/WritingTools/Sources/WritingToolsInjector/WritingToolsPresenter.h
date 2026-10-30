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
- (BOOL)presentToolControllerFromExternalSource:(UIResponder *)responder;
- (BOOL)presentToolControllerStandalone:(UIResponder *)responder;
/// 3.0.78: same standalone card, but the panel opens already tokenized. Used for
/// `faircopy://panel?keyword=…&mode=segment`, which Kayoko sends after OCR-ing a
/// clipboard picture. Declared here only so the injector can call it without an
/// undeclared-selector warning — the implementation lives in Swift
/// (`Presenter+Open.swift`, `@objc(presentToolControllerStandalone:autoSegment:)`).
- (BOOL)presentToolControllerStandalone:(UIResponder *)responder autoSegment:(BOOL)autoSegment;
- (void)presentUnavailable:(UIResponder *)responder;
@end

NS_ASSUME_NONNULL_END
