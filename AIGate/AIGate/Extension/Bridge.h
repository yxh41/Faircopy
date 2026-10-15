//
//  Bridge.h
//  AIGate
//
//  Created by 秋星桥 on 2024/8/16.
//

#import "./Jetsam/Jetsam.h"

#import "GateSessionDelegate.h"

#import <Foundation/Foundation.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)arg1;
@end
