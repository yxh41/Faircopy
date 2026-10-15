//
//  WritingToolsMenu.h
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/20.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN NSString *WT_AppleMenuIdentifier(void);

FOUNDATION_EXTERN UIMenuItem *WT_MenuItem(void);
FOUNDATION_EXTERN UICommand *WT_MenuItem_UICommand(void);

FOUNDATION_EXTERN BOOL WT_MenuItem_IsWritingTool(id input);

NS_ASSUME_NONNULL_END
