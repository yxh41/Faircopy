//
//  PrivateClasses.h
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/19.
//

#include <UIKit/UIKit.h>

@interface UIMenu (Private)
- (UIMenu *)menuByReplacingChildren:(NSArray *)children;
@end


@interface _UICalloutBarSystemButtonDescription : NSObject
@property (nonatomic, readonly) SEL action;
+ (instancetype)buttonDescriptionWithTitle:(NSString *)arg1 action:(SEL)arg2 type:(int)arg3 ;
@end

@interface UICalloutBar : UIView
@end
