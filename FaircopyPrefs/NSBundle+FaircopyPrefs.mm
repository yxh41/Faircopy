#import "NSBundle+FaircopyPrefs.h"

#import <libroot.h>

@implementation NSBundle (Faircopy)

+ (NSBundle *)wrti_supportBundle {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      NSString *tweakBundlePath;
      tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"FaircopyPrefs" ofType:@"bundle"];
      NSString *aliasBundlePath;
      aliasBundlePath = JBROOT_PATH_NSSTRING(@"/Library/PreferenceBundles/FaircopyPrefs.bundle");
      bundle = [NSBundle bundleWithPath:tweakBundlePath ?: aliasBundlePath];
    });
    return bundle;
}

+ (NSString *)wrti_packageVersion {
    return @PACKAGE_VERSION;
}

@end