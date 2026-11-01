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
/// 3.0.96: the same card, told in words what to run first ("segment", "translate").
/// The injector passes the caller's mode through untouched, so a third kind of
/// automatic start needs no new selector. Implemented in `Presenter+Open.swift`
/// as `@objc(presentToolControllerStandalone:mode:)`.
- (BOOL)presentToolControllerStandalone:(UIResponder *)responder mode:(NSString *)mode;
- (void)presentUnavailable:(UIResponder *)responder;
@end

NS_ASSUME_NONNULL_END
