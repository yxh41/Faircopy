//
//  WritingToolsMenu.m
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/20.
//

#import "WritingToolsInjector.h"
#import "WritingToolsPresenter.h"
#import "WritingToolsMenu.h"

NSString *WT_AppleMenuIdentifier(void) {
    return @"com.apple.menu.standard-edit";
}

UIMenuItem *WT_MenuItem(void) {
    static UIMenuItem *menuItem = nil;
    if (!menuItem) {
        WritingToolsPresenter *presenter = [WritingToolsPresenter sharedInstance];
        menuItem = [[UIMenuItem alloc] initWithTitle:presenter.writingToolMenuName
                                              action:NSSelectorFromString(@kWritingToolSelectorName)];
    }
    return menuItem;
}

UICommand *WT_MenuItem_UICommand(void) {
    static UICommand *command = nil;
    if (!command) {
        WritingToolsPresenter *presenter = [WritingToolsPresenter sharedInstance];
        command = [UICommand commandWithTitle:presenter.writingToolMenuName
                                        image:nil
                                       action:NSSelectorFromString(@kWritingToolSelectorName)
                                    propertyList:nil];
    }
    return command;
}

BOOL WT_MenuItem_IsWritingTool(id input) {
    if ([input isKindOfClass:[UIMenu class]]) {
        UIMenu *menu = (UIMenu *)input;
        if ([menu.title isEqualToString:WT_MenuItem().title]) {
            return YES;
        }
    }
    if ([input isKindOfClass:[UIAction class]]) {
        UIAction *action = (UIAction *)input;
        if ([action.title isEqualToString:WT_MenuItem().title]) {
            return YES;
        }
    }
    if ([input isKindOfClass:[UICommand class]]) {
        UICommand *command = (UICommand *)input;
        NSString *selectorName = NSStringFromSelector(command.action);
        if ([selectorName isEqualToString:@kWritingToolSelectorName]) {
            return YES;
        }
    }
    return NO;
}
