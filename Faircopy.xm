%config(generator=internal);

#import <HBLog.h>

@import UIKit;
@import WritingToolsInjector;

@interface UIResponder (Faircopy)
- (id)_responderForEditing;
@end

%group FaircopyUniversal

%hook WKContentView

%property(nonatomic, strong) NSString *fc_selectedText;
%property(nonatomic, strong) dispatch_semaphore_t fc_isGettingSelectedTextSemaphore;

%new
- (void)accessibilitySpeakSelectionSetContent:(NSString *)string {
    self.fc_selectedText = string;
    if (self.fc_isGettingSelectedTextSemaphore)
        dispatch_semaphore_signal(self.fc_isGettingSelectedTextSemaphore);
}

%end

%hook UIResponder

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    BOOL origRet = %orig;

    NSString *actionName = NSStringFromSelector(action);
    BOOL isWritingToolAction = [actionName isEqualToString:@kWritingToolSelectorName];
    if (!origRet || !isWritingToolAction) {
        return origRet;
    }

    UIResponder *responder = FC_LastEditingResponder();
    if ([responder isKindOfClass:[UITextView class]]) {
        UITextView *textView = (UITextView *)responder;
        return [textView isEditable];
    }
    else if ([responder isKindOfClass:[UITextField class]]) {
        return YES;
    }
    else if ([responder isKindOfClass:%c(WKContentView)]) {
        WKContentView *contentView = (WKContentView *)responder;
        return ![contentView.selectedTextRange isEmpty];
    }

    return NO;
}

- (UIResponder *)_responderForEditing {
    UIResponder *responder = %orig;
    FC_SetLastEditingResponder(responder);

    HBLogDebug(@"_responderForEditing: %@", responder);
    return responder;
}

%end

%end

%ctor {
    HBLogDebug(@"loaded!");
    %init(FaircopyUniversal);
}