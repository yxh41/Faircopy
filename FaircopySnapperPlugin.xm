%config(generator=internal);

//
//  FaircopySnapperPlugin.xm
//
//  Snapper3 plugin so that Faircopy shows up in the screen-capture menus of
//  Snapper3 and of ShellX (ShellX does not have its own plugin format: it
//  reuses Snapper3's plugin table, so one implementation lands in both menus).
//
//  Why this file exists at all:
//  ShellX's area-capture window builds one button per entry in its plugin list
//  (`-[SSAreaCaptureWindow reloadPluginsUI]` -> `buildActionBtn:icon:color:sel:`
//  -> `pluginActionBtnTapped:` -> `pluginForId:`), and that list is filled by
//  `-[Snapper3PluginManager registerPlugin:]`.  A plugin therefore needs two
//  things and nothing more: an object that answers the plugin protocol, and an
//  instance of it inside the manager.  The metadata plists under
//  /var/mobile/Library/Snapper3/Plugins are only names and icons for plugins
//  that ship their own dylib; this tweak is already injected into every UIKit
//  process (`Faircopy.plist` filters on com.apple.UIKit), so the dylib is in
//  the room before the manager is built and registers itself instead.
//
//  What tapping it does: the same picture hand-off Kayoko already uses, so no
//  new plumbing is needed on the app side — write the picture into the shared
//  directory, post `wiki.qaq.faircopy.ocr.request`, and the resident AIGate
//  reads it with Vision, leaves a `mode=segment` invocation where the injector
//  will find it and posts the present broadcast.  The panel opens in the app
//  the user is looking at, already segmented.
//

#import <HBLog.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

@import UIKit;

// KEEP IN SYNC with FaircopyImageOCR in AIGate/AIGate/Editor/FaircopyApp.swift.
static NSString *const kFCSharedDirectory = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate";
static NSString *const kFCInputPath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr_input.img";
static NSString *const kFCDisplayTargetPath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr_target.txt";
static NSString *const kFCRecognizeLogPath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr.log";
static NSString *const kFCRequestNotification = @"wiki.qaq.faircopy.ocr.request";
static NSString *const kFCResultNotification = @"wiki.qaq.faircopy.ocr.result";

// Our own diagnostics.  A plugin either appears in somebody's menu or it does
// not, and there is no way to tell from the outside which of the three
// managers was involved — so every step writes one line here.
static NSString *const kFCLogPath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_snapper.log";

static NSString *const kFCPluginIdentifier = @"wiki.qaq.snapper3.plugin.faircopy";
static NSString *const kFCFallbackURL = @"faircopy://ocr";
static NSString *const kFCPluginsDirectory = @"/var/mobile/Library/Snapper3/Plugins";

#pragma mark - log

static void FCLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSDateFormatter *stampFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stampFormatter = [[NSDateFormatter alloc] init];
        stampFormatter.dateFormat = @"HH:mm:ss.SSS";
    });

    NSString *stamped = [NSString stringWithFormat:@"%@ [%@] %@\n",
                         [stampFormatter stringFromDate:[NSDate date]],
                         NSProcessInfo.processInfo.processName,
                         line];
    NSData *data = [stamped dataUsingEncoding:NSUTF8StringEncoding];
    if (!data)
        return;

    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:kFCLogPath]) {
        [data writeToFile:kFCLogPath atomically:YES];
        return;
    }
    // Self-trimming, exactly like faircopy_ocr.log: the file can never grow
    // past this, so leaving it installed costs nothing.
    NSDictionary *attributes = [manager attributesOfItemAtPath:kFCLogPath error:NULL];
    if ([attributes fileSize] > 8192)
        [@"" writeToFile:kFCLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kFCLogPath];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (NSException *exception) {
    }
    [handle closeFile];
}

#pragma mark - small runtime helpers

/// Every plugin object in this corner of the system answers `pluginIdentifier`,
/// but none of their headers exist here.  One cast keeps the compiler quiet
/// without pretending to know the class.
static id FCPerform(id object, NSString *selectorName)
{
    if (!object)
        return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector])
        return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (NSException *exception) {
        return nil;
    }
}

static NSString *FCPluginIdentifierOf(id plugin)
{
    id value = FCPerform(plugin, @"pluginIdentifier");
    if (![value isKindOfClass:[NSString class]])
        value = FCPerform(plugin, @"name");
    if ([value isKindOfClass:[NSString class]] && [value length] > 0)
        return value;
    return plugin ? NSStringFromClass([plugin class]) : @"(nil)";
}

/// The list the manager is working on, read straight out of the ivar.
///
/// Calling `-plugins` from inside a hook on the manager would re-enter whatever
/// the manager is in the middle of doing, so the array is taken by address.
static NSArray *FCPluginsOf(id manager)
{
    if (!manager)
        return nil;
    // Snapper3's own manager spells its ivars without the underscore
    // (`plugins`, `allPlugins`), ShellX's shim with it. Try both.
    for (NSString *name in @[@"_plugins", @"plugins", @"_allPlugins", @"allPlugins"]) {
        Ivar ivar = class_getInstanceVariable(object_getClass(manager), name.UTF8String);
        if (!ivar)
            continue;
        id value = object_getIvar(manager, ivar);
        if ([value isKindOfClass:[NSArray class]])
            return value;
    }
    return nil;
}

static NSString *FCDescribePlugins(NSArray *plugins)
{
    if (!plugins)
        return @"(no list)";
    NSMutableArray *names = [NSMutableArray array];
    for (id plugin in plugins) {
        if (names.count >= 24) {
            [names addObject:@"…"];
            break;
        }
        [names addObject:FCPluginIdentifierOf(plugin)];
    }
    return [NSString stringWithFormat:@"%lu [%@]",
            (unsigned long)plugins.count,
            [names componentsJoinedByString:@", "]];
}

static BOOL FCListContainsPlugin(NSArray *plugins)
{
    for (id plugin in plugins) {
        if ([FCPluginIdentifierOf(plugin) isEqualToString:kFCPluginIdentifier])
            return YES;
    }
    return NO;
}

#pragma mark - plugin object

@interface FaircopySnapperPlugin : NSObject
@end

static FaircopySnapperPlugin *FCSnapperPlugin(void)
{
    static FaircopySnapperPlugin *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FaircopySnapperPlugin alloc] init];
    });
    return instance;
}

/// The menu image.  Drawn instead of installed: a png under layout/ would have
/// to be placed in a real /var/mobile path, which a roothide package cannot do.
///
/// Deliberately *not* a template image.  Snapper3's own plugins ship coloured
/// artwork and the menu draws it as it comes, so a white-on-clear glyph either
/// disappears on a light menu or turns into a flat silhouette — 3.0.90 did
/// exactly that.  This is a small app-icon instead: the teal gradient and the
/// white ring from the Faircopy UI, with the glyph on top.
static UIImage *FCMenuIcon(void)
{
    static UIImage *icon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGFloat side = 120.0;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.opaque = NO;
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];

        icon = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextRef cgContext = context.CGContext;
            CGRect box = CGRectInset(CGRectMake(0, 0, side, side), 3, 3);
            UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:box cornerRadius:28];
            [shape addClip];

            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGFloat components[8] = {
                0.043, 0.216, 0.216, 1.0,
                0.086, 0.376, 0.361, 1.0,
            };
            CGFloat locations[2] = {0.0, 1.0};
            CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 2);
            CGContextDrawLinearGradient(cgContext, gradient,
                                        CGPointMake(0, 0), CGPointMake(side, side), 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);

            [[UIColor colorWithWhite:1.0 alpha:0.45] setStroke];
            UIBezierPath *ring =
                [UIBezierPath bezierPathWithRoundedRect:CGRectInset(box, 7, 7) cornerRadius:22];
            ring.lineWidth = 2.5;
            [ring stroke];

            NSDictionary *attributes = @{
                NSFontAttributeName: [UIFont systemFontOfSize:58 weight:UIFontWeightHeavy],
                NSForegroundColorAttributeName: UIColor.whiteColor,
            };
            CGSize size = [@"译" sizeWithAttributes:attributes];
            [@"译" drawAtPoint:CGPointMake((side - size.width) / 2.0, (side - size.height) / 2.0)
                withAttributes:attributes];
        }];

        icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return icon;
}

#pragma mark - finding the picture ShellX never hands over

/// A struct ivar, read by address.  `object_getIvar` only works for object
/// pointers, and the crop rectangle is the whole point of this.
static BOOL FCReadCGRectIvar(id object, NSString *name, CGRect *out)
{
    if (!object || !out)
        return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name.UTF8String);
    if (!ivar)
        return NO;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || strncmp(type, "{CGRect", 7) != 0)
        return NO;
    *out = *(CGRect *)((char *)(__bridge void *)object + ivar_getOffset(ivar));
    return YES;
}

static UIImage *FCReadImageIvar(id object, NSString *name)
{
    if (!object)
        return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name.UTF8String);
    if (!ivar)
        return nil;
    id value = object_getIvar(object, ivar);
    return [value isKindOfClass:[UIImage class]] ? (UIImage *)value : nil;
}

static UIImage *FCCropImage(UIImage *image, CGRect crop)
{
    if (!image)
        return nil;
    CGRect full = CGRectMake(0, 0, image.size.width, image.size.height);
    crop = CGRectIntegral(CGRectIntersection(crop, full));
    if (crop.size.width < 8 || crop.size.height < 8)
        return image;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = image.scale > 0 ? image.scale : 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:crop.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawAtPoint:CGPointMake(-crop.origin.x, -crop.origin.y)];
    }];
}

/// ShellX's capture window keeps everything we need and hands our plugin
/// nothing: `_ssOrigCaptureImage` is the frozen full-screen frame, and
/// `_selectionRect` / `_ssOrigCaptureBounds` say which part of it the user
/// picked.  So the picture is taken from the window itself rather than from the
/// argument, which is only an `SSSnapperCropShim` (its `messagingDelegate`
/// answers `displayMessage:` and nothing else).
static UIImage *FCImageFromCropOwner(id owner, NSString **explanation)
{
    UIImage *full = FCReadImageIvar(owner, @"_ssOrigCaptureImage");
    if (!full)
        return nil;

    CGRect selection = CGRectZero;
    CGRect bounds = CGRectZero;
    BOOL hasSelection = FCReadCGRectIvar(owner, @"_selectionRect", &selection);
    BOOL hasBounds = FCReadCGRectIvar(owner, @"_ssOrigCaptureBounds", &bounds);

    // The frozen frame is in pixels, the selection is in points: the capture
    // bounds are the bridge between the two.
    CGRect basis = CGRectZero;
    if (hasBounds && bounds.size.width >= 1 && bounds.size.height >= 1)
        basis = bounds;
    else if ([owner isKindOfClass:[UIView class]])
        basis = CGRectMake(0, 0, ((UIView *)owner).bounds.size.width, ((UIView *)owner).bounds.size.height);

    CGRect crop = CGRectMake(0, 0, full.size.width, full.size.height);
    if (hasSelection && selection.size.width >= 4 && selection.size.height >= 4 &&
        basis.size.width >= 1 && basis.size.height >= 1) {
        CGFloat scaleX = full.size.width / basis.size.width;
        CGFloat scaleY = full.size.height / basis.size.height;
        crop = CGRectMake((selection.origin.x - basis.origin.x) * scaleX,
                          (selection.origin.y - basis.origin.y) * scaleY,
                          selection.size.width * scaleX,
                          selection.size.height * scaleY);
    }
    if (explanation) {
        *explanation = [NSString stringWithFormat:
            @"%@ frame=%.0fx%.0f selection=%@ bounds=%@ crop=%@",
            NSStringFromClass([owner class]),
            full.size.width, full.size.height,
            NSStringFromCGRect(selection), NSStringFromCGRect(bounds),
            NSStringFromCGRect(crop)];
    }
    return FCCropImage(full, crop);
}

static UIWindow *FCCaptureWindow(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (FCReadImageIvar(window, @"_ssOrigCaptureImage"))
                return window;
    }
    return nil;
}

static UIImage *FCImageFromCaptureWindow(NSString **explanation)
{
    return FCImageFromCropOwner(FCCaptureWindow(), explanation);
}

/// Find a capture window that `connectedScenes` does not list.
///
/// ShellX builds its capture window from its own window scene, so the scene
/// enumeration above can come up empty even though the window is right there.
/// Every window in the process is reachable from the application object itself
/// (`UIApplication` keeps them in its own array ivar), so this walks the graph
/// looking for the one object that carries `_ssOrigCaptureImage`.
///
/// Only that object counts — a stray UIImage picked out of SpringBoard's view
/// tree would be somebody's wallpaper, which is worse than nothing.
static UIImage *FCImageFromGraph(id root, NSString **explanation)
{
    NSMutableArray *queue = [NSMutableArray array];
    if (root)
        [queue addObject:root];
    id delegate = FCPerform(root, @"messagingDelegate");
    if (delegate && delegate != root)
        [queue addObject:delegate];
    // Seeded with the application, not its delegate: the windows hang off the
    // application's own ivar, and BFS reaches them within the first few hops.
    [queue addObject:UIApplication.sharedApplication];
    if (UIApplication.sharedApplication.delegate)
        [queue addObject:UIApplication.sharedApplication.delegate];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            [queue addObject:window];
    }

    NSMutableSet *visited = [NSMutableSet set];
    NSInteger budget = 3000;
    while (queue.count > 0 && budget-- > 0) {
        id object = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!object)
            continue;
        NSString *key = [NSString stringWithFormat:@"%p", (__bridge void *)object];
        if ([visited containsObject:key])
            continue;
        [visited addObject:key];

        UIImage *cropped = FCImageFromCropOwner(object, explanation);
        if (cropped)
            return cropped;

        if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] ||
            [object isKindOfClass:[NSData class]] || [object isKindOfClass:[NSDate class]] ||
            [object isKindOfClass:[UIImage class]])
            continue;
        if ([object isKindOfClass:[NSArray class]]) {
            for (id element in (NSArray *)object)
                if (queue.count < 4000)
                    [queue addObject:element];
            continue;
        }
        if ([object isKindOfClass:[NSDictionary class]]) {
            for (id element in [(NSDictionary *)object allValues])
                if (queue.count < 4000)
                    [queue addObject:element];
            continue;
        }

        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(object_getClass(object), &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (!type || type[0] != '@')
                continue;
            id value = object_getIvar(object, ivars[index]);
            if (value && queue.count < 4000)
                [queue addObject:value];
        }
        if (ivars)
            free(ivars);
    }
    return nil;
}

/// Written when nothing could be found, so the next version does not have to
/// guess again: the argument, its delegate, and their object ivars by name.
static void FCDumpGraph(id root)
{
    NSMutableString *dump = [NSMutableString string];
    [dump appendFormat:@"root: %@\n", NSStringFromClass([root class])];

    NSMutableArray *objects = [NSMutableArray array];
    if (root)
        [objects addObject:root];
    id delegate = FCPerform(root, @"messagingDelegate");
    if (delegate && delegate != root)
        [objects addObject:delegate];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            [objects addObject:window];
    }

    for (id object in objects) {
        [dump appendFormat:@"\n[%@] %p\n", NSStringFromClass([object class]), (__bridge void *)object];
        Class cls = object_getClass(object);
        while (cls && cls != [NSObject class]) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int index = 0; index < count; index++) {
                const char *name = ivar_getName(ivars[index]);
                const char *type = ivar_getTypeEncoding(ivars[index]);
                if (!name || !type)
                    continue;
                if (type[0] == '@') {
                    id value = object_getIvar(object, ivars[index]);
                    [dump appendFormat:@"  %s : %s\n", name,
                                      value ? NSStringFromClass([value class]).UTF8String : "nil"];
                }
                else {
                    [dump appendFormat:@"  %s : %s\n", name, type];
                }
            }
            if (ivars)
                free(ivars);
            cls = class_getSuperclass(cls);
        }
    }

    NSData *data = [dump dataUsingEncoding:NSUTF8StringEncoding];
    [data writeToFile:@"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_snapper_tree.log"
              atomically:YES];
}


/// The snap object is a private class, so the picture is fetched by asking for
/// the usual names and, failing that, by drawing whatever view was handed over.
/// Everything is wrapped: a wrong guess must cost a log line, not a crash in
/// somebody else's capture window.
static UIImage *FCImageFromSnap(id snap)
{
    if (!snap)
        return nil;
    if ([snap isKindOfClass:[UIImage class]])
        return (UIImage *)snap;

    for (NSString *key in @[@"image", @"snapImage", @"snappedImage", @"snapshot", @"contentImage"]) {
        id value = FCPerform(snap, key);
        if ([value isKindOfClass:[UIImage class]])
            return (UIImage *)value;
    }
    @try {
        id value = [snap valueForKey:@"image"];
        if ([value isKindOfClass:[UIImage class]])
            return (UIImage *)value;
    } @catch (NSException *exception) {
    }

    if ([snap isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)snap;
        if (view.bounds.size.width >= 1 && view.bounds.size.height >= 1) {
            UIGraphicsImageRenderer *renderer =
                [[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size];
            return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
            }];
        }
    }
    return nil;
}

#pragma mark - hand-off

static void FCOpenURL(NSURL *url)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = nil;
    if (workspaceClass && [workspaceClass respondsToSelector:@selector(defaultWorkspace)])
        workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));

    if (workspace && [workspace respondsToSelector:@selector(openURL:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(workspace, @selector(openURL:), url);
        return;
    }
    if (workspace && [workspace respondsToSelector:@selector(openURL:withOptions:)]) {
        NSMethodSignature *signature = [workspace methodSignatureForSelector:@selector(openURL:withOptions:)];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:workspace];
        [invocation setSelector:@selector(openURL:withOptions:)];
        NSURL *argument = url;
        NSDictionary *options = @{};
        [invocation setArgument:(void *)&argument atIndex:2];
        [invocation setArgument:(void *)&options atIndex:3];
        [invocation invoke];
        return;
    }
    FCLog(@"fallback road unavailable: no LSApplicationWorkspace");
}

static int fcResultToken = 0;
static uint64_t fcInvocationSequence = 0;

static void FCWatchForResult(void)
{
    if (fcResultToken != 0)
        return;
    uint32_t status = notify_register_dispatch(kFCResultNotification.UTF8String,
                                               &fcResultToken,
                                               dispatch_get_main_queue(),
                                               ^(int token) {
        fcInvocationSequence++;
        FCLog(@"result notification arrived, fallback cancelled");
    });
    if (status != NOTIFY_STATUS_OK)
        FCLog(@"could not watch %@: %u", kFCResultNotification, status);
}

/// A resident AIGate answers the request notification within a second or two.
/// If it is not running at all — freshly installed, killed by memory pressure —
/// nothing ever answers, and the only way left is the visible road: a URL
/// launch that AIGate immediately hides, recognising the same picture it finds
/// on disk and bouncing straight back.  Six seconds is far longer than a
/// recognition and short enough that a dead hand-off is not silent forever.
static void FCArmFallback(void)
{
    FCWatchForResult();
    uint64_t mine = ++fcInvocationSequence;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (fcInvocationSequence != mine)
            return;
        FCLog(@"no answer in 6s, opening %@", kFCFallbackURL);
        FCOpenURL([NSURL URLWithString:kFCFallbackURL]);
    });
}

static void FCHandOffImage(UIImage *image, NSString *source)
{
    if (![image isKindOfClass:[UIImage class]] || image.size.width < 1 || image.size.height < 1) {
        FCLog(@"%@: no usable picture", source);
        return;
    }
    FCLog(@"%@: picture %.0fx%.0f", source, image.size.width, image.size.height);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSData *data = UIImagePNGRepresentation(image);
            if (!data || data.length > (8u * 1024u * 1024u)) {
                NSData *jpeg = UIImageJPEGRepresentation(image, 0.95);
                if (jpeg)
                    data = jpeg;
            }
            if (!data) {
                FCLog(@"%@: could not encode the picture", source);
                return;
            }

            NSFileManager *manager = [NSFileManager defaultManager];
            [manager createDirectoryAtPath:kFCSharedDirectory
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:NULL];
            NSError *error = nil;
            if (![data writeToFile:kFCInputPath options:NSDataWritingAtomic error:&error]) {
                FCLog(@"%@: write failed (%@)", source, error.localizedDescription);
                return;
            }
            // Deliberately no display-target file: an empty one is what the
            // injector reads as "let the ticket arbitrate", and a stale target
            // left behind by an earlier Kayoko swipe would send the panel to an
            // app that is not on screen any more.
            [manager removeItemAtPath:kFCDisplayTargetPath error:NULL];

            FCLog(@"%@: handed off %lu bytes", source, (unsigned long)data.length);
            notify_post(kFCRequestNotification.UTF8String);
            dispatch_async(dispatch_get_main_queue(), ^{
                FCArmFallback();
                // Whether the panel can be seen depends on whether the capture
                // window is still on top of it: one line, a second and a half
                // later, says which of the two happened.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIWindow *window = FCCaptureWindow();
                    FCLog(@"capture window 1.5 s after the tap: %@",
                          window ? (window.hidden ? @"still there, hidden" : @"still there, visible")
                                 : @"gone");
                });
            });
        }
    });
}

@implementation FaircopySnapperPlugin

- (NSString *)name { return @"Faircopy 翻译"; }
- (NSString *)info { return @"用 Faircopy 识别并翻译截图里的文字"; }
- (NSString *)developer { return @"hxy24"; }
- (NSString *)email { return @""; }
- (NSString *)twitter { return @""; }
- (NSString *)website { return @""; }
- (NSString *)tweakIdentifier { return @"wiki.qaq.faircopy"; }
- (NSString *)pluginIdentifier { return kFCPluginIdentifier; }

- (BOOL)showInSettings { return YES; }
- (BOOL)disabledInitially { return NO; }
- (BOOL)shouldRegister { return YES; }

/// YES so the capture window closes behind the panel instead of leaving a
/// frozen screenshot on top of the very app the panel is about to open in.
- (BOOL)removeSnapAfterProcessing { return YES; }

- (UIImage *)image { return FCMenuIcon(); }
- (UIImage *)imageForMenuAndSettings { return FCMenuIcon(); }

/// Menu road — this is the one with the snap attached.
- (void)internal_doMenuAction:(id)action forSnap:(id)snap
{
    FCLog(@"menu action from %@, snap %@",
          NSStringFromClass([action class]), NSStringFromClass([snap class]));
    UIImage *image = FCImageFromSnap(snap);
    if (!image) {
        NSString *explanation = nil;
        image = FCImageFromCaptureWindow(&explanation);
        FCLog(@"menu action: snap gave nothing, window gave %@", explanation ?: @"nothing");
    }
    FCHandOffImage(image, @"menu");
}

/// Picture road — plugins that only implement this are handed the finished
/// image directly.  Kept because it is the cheaper of the two contracts and
/// because a caller that skips the menu path still reaches us.
- (void)processImage:(UIImage *)image
{
    FCLog(@"processImage: entry");
    FCHandOffImage(image, @"processImage");
}

/// Action-bar road — and this is the one ShellX actually uses (3.0.90 log:
/// `action bar action from SSSnapperCropShim`, three taps in a row).  The
/// argument carries no picture, so it comes from the capture window instead.
- (void)internal_doActionBarAction:(id)action
{
    NSString *explanation = nil;
    UIImage *image = FCImageFromCaptureWindow(&explanation);
    if (image)
        FCLog(@"action bar action from %@: %@",
              NSStringFromClass([action class]), explanation ?: @"window");
    if (!image) {
        NSString *graphExplanation = nil;
        image = FCImageFromGraph(action, &graphExplanation);
        if (image)
            FCLog(@"action bar action from %@: picture from the argument graph, %@",
                  NSStringFromClass([action class]), graphExplanation ?: @"unnamed");
    }
    if (!image) {
        FCDumpGraph(action);
        FCLog(@"action bar action from %@: no picture anywhere, graph dumped",
              NSStringFromClass([action class]));
        return;
    }
    FCHandOffImage(image, @"action bar");
}

@end

#pragma mark - registration

/// Both menus are filled from a manager instance, and neither exposes a shared
/// one, so the only reliable moment is the instance's own construction.
static BOOL fcRegistering = NO;

static void FCRegisterIntoManager(id manager, NSString *how)
{
    if (!manager || fcRegistering)
        return;

    fcRegistering = YES;
    @try {
        NSArray *existing = FCPluginsOf(manager);
        if (FCListContainsPlugin(existing)) {
            FCLog(@"%@: %@ already holds %@",
                  how, NSStringFromClass([manager class]), kFCPluginIdentifier);
            return;
        }

        if ([manager respondsToSelector:@selector(registerPlugin:)]) {
            id plugin = FCSnapperPlugin();
            ((void (*)(id, SEL, id))objc_msgSend)(manager, @selector(registerPlugin:), plugin);
            NSArray *after = FCPluginsOf(manager);
            FCLog(@"%@: registered into %@, before=%@ after=%@",
                  how, NSStringFromClass([manager class]),
                  FCDescribePlugins(existing), FCDescribePlugins(after));
        }
        else {
            FCLog(@"%@: %@ has no registerPlugin:",
                  how, NSStringFromClass([manager class]));
        }
    } @finally {
        fcRegistering = NO;
    }
}

/// Appending straight into a list we already hold. Used where the manager is
/// provably between mutations, never from a getter somebody may be enumerating.
static void FCEnsurePluginInList(NSArray *list, NSString *how)
{
    if (![list isKindOfClass:[NSMutableArray class]] || fcRegistering)
        return;
    if (FCListContainsPlugin(list))
        return;

    fcRegistering = YES;
    [(NSMutableArray *)list addObject:FCSnapperPlugin()];
    fcRegistering = NO;
    FCLog(@"%@: appended -> %@", how, FCDescribePlugins(list));
}

/// Snapper3's manager answers `conformsToProtocol:` for the real protocol
/// object, which only exists once Snapper3 itself is loaded — so the class
/// adopts it here, at the first moment the two images are both in the room.
static void FCAdoptSnapperProtocol(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Protocol *protocol = objc_getProtocol("Snapper3Plugin");
        Class pluginClass = [FaircopySnapperPlugin class];
        if (protocol) {
            BOOL adopted = class_addProtocol(pluginClass, protocol);
            FCLog(@"adopted Snapper3Plugin protocol (%@)", adopted ? @"new" : @"already");
        }
        else {
            FCLog(@"Snapper3Plugin protocol not present; relying on duck typing");
        }
    });
}

@interface Snapper3PluginManager : NSObject
@end

@interface SHELLXPluginManager : NSObject
@end

@interface SSAreaCaptureWindow : NSObject
@end

@interface NSObject (FaircopySnapperWindow)
- (id)pluginForId:(NSString *)identifier;
@end

%group FaircopySnapper

%hook Snapper3PluginManager

- (id)init
{
    id manager = %orig;
    FCAdoptSnapperProtocol();
    FCRegisterIntoManager(manager, @"init");
    return manager;
}

- (void)registerPlugin:(id)plugin
{
    %orig;
    FCLog(@"Snapper3PluginManager registered %@", FCPluginIdentifierOf(plugin));
    // Second chance for the case where this image loaded after the manager was
    // built and our `init` hook therefore never saw it. Safe to append here:
    // the manager is already mid-mutation, so nothing is being enumerated.
    FCRegisterIntoManager(self, @"registerPlugin: follow-up");
}

%end

%hook SHELLXPluginManager

- (id)init
{
    id manager = %orig;
    FCAdoptSnapperProtocol();
    FCRegisterIntoManager(manager, @"shellx init");
    return manager;
}

- (void)setPlugins:(NSArray *)plugins
{
    %orig;
    FCLog(@"SHELLX setPlugins: %@", FCDescribePlugins(plugins));

    // ShellX keeps its own copy of the list.  If it ever rebuilds that copy
    // from somewhere that does not know about us, the plugin would be
    // registered with Snapper3 and still be missing from ShellX's menu.
    FCEnsurePluginInList(plugins, @"SHELLX setPlugins:");
}

/// The copy step ShellX runs whenever its capture UI or its settings page is
/// about to read the plugin table.  Everything is in place before the original
/// runs, so the buttons it builds include ours.
- (void)syncPluginsToSettings
{
    FCAdoptSnapperProtocol();
    FCEnsurePluginInList(FCPluginsOf(self), @"SHELLX syncPluginsToSettings");
    %orig;
}

%end

%hook SSAreaCaptureWindow

- (void)reloadPluginsUI
{
    %orig;
    NSString *found = @"no pluginForId:";
    if ([self respondsToSelector:@selector(pluginForId:)]) {
        @try {
            id plugin = [self pluginForId:kFCPluginIdentifier];
            found = plugin ? [NSString stringWithFormat:@"%@ -> %@",
                              kFCPluginIdentifier, NSStringFromClass([plugin class])]
                           : [NSString stringWithFormat:@"%@ -> nil", kFCPluginIdentifier];
        } @catch (NSException *exception) {
            found = [NSString stringWithFormat:@"lookup threw %@", exception.name];
        }
    }
    FCLog(@"reloadPluginsUI: %@", found);
}

- (void)pluginActionBtnTapped:(id)sender
{
    NSString *tag = @"-";
    if ([sender isKindOfClass:[UIView class]])
        tag = [NSString stringWithFormat:@"%ld", (long)((UIView *)sender).tag];
    FCLog(@"pluginActionBtnTapped: %@ tag=%@", NSStringFromClass([sender class]), tag);
    %orig;
    FCLog(@"pluginActionBtnTapped: done");
}

%end

%end

%ctor {
    @autoreleasepool {
        NSFileManager *manager = [NSFileManager defaultManager];
        BOOL snapperInstalled = (NSClassFromString(@"Snapper3PluginManager") != nil);
        BOOL shellxInstalled = (NSClassFromString(@"SHELLXPluginManager") != nil);
        BOOL pluginsFolder = [manager fileExistsAtPath:kFCPluginsDirectory];
        // Silent in the hundreds of processes that have neither of them: a line
        // per app launch would trim the useful part of the log away within an
        // hour. A process that can show the plugin is a process worth a line.
        if (snapperInstalled || shellxInstalled || pluginsFolder) {
            FCLog(@"loaded: snapper=%d shellx=%d metadata folder=%d recognize log=%d",
                  snapperInstalled, shellxInstalled, pluginsFolder,
                  [manager fileExistsAtPath:kFCRecognizeLogPath]);
        }
        %init(FaircopySnapper);
    }
}
