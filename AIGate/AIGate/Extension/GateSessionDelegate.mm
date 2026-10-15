#import "GateSessionDelegate.h"

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <stdlib.h>

FOUNDATION_EXTERN CFTypeRef _CTServerConnectionCreate(CFAllocatorRef, void *, void *);
FOUNDATION_EXTERN int64_t _CTServerConnectionSetCellularUsagePolicy(CFTypeRef ct, CFStringRef identifier,
                                                                    CFDictionaryRef policies);

static void GrantNetworkAccess(void) {
    CFTypeRef ctConn = _CTServerConnectionCreate(kCFAllocatorDefault, NULL, NULL);
    _CTServerConnectionSetCellularUsagePolicy
    (
     ctConn,
     CFSTR("wiki.qaq.AIGate"),
     (__bridge CFDictionaryRef)(@{
        @"kCTCellularDataUsagePolicy" : @"kCTCellularDataUsagePolicyAlwaysAllow",
        @"kCTWiFiDataUsagePolicy" : @"kCTCellularDataUsagePolicyAlwaysAllow"
     }));
    CFRelease(ctConn);
}

static void MonitorSelfAndExitIfVnodeDeleted(void) {
    const char *executablePath = [[[[NSProcessInfo processInfo] arguments] firstObject] fileSystemRepresentation];
    static unsigned long monitorMask = DISPATCH_VNODE_DELETE;
    int selfHandle = open(executablePath, O_EVTONLY);
    if (selfHandle <= 0) {
        return;
    }
    static dispatch_source_t monitorSource;
    monitorSource =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, selfHandle, monitorMask, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(monitorSource, ^{
      unsigned long flags = dispatch_source_get_data(monitorSource);
      if (flags & DISPATCH_VNODE_DELETE) {
          dispatch_source_cancel(monitorSource);
          exit(EXIT_SUCCESS);
      }
    });
    dispatch_resume(monitorSource);
}

@implementation GateSessionDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        GrantNetworkAccess();
        MonitorSelfAndExitIfVnodeDeleted();
    }
    return self;
}

@end
