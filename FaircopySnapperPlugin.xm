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

/// 3.0.96: what the panel should do with the recognised words. The menu item is
/// called 「Faircopy 翻译」, so this entry asks for a translation; every other
/// caller (Kayoko) leaves the file absent and keeps 分词.
/// KEEP IN SYNC with FaircopyImageOCR.modePath.
static NSString *const kFCModePath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr_mode.txt";
static NSString *const kFCModeTranslate = @"translate";
static NSString *const kFCRecognizeLogPath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr.log";
static NSString *const kFCRequestNotification = @"wiki.qaq.faircopy.ocr.request";
static NSString *const kFCResultNotification = @"wiki.qaq.faircopy.ocr.result";

/// 3.0.97: the resident worker's heart beat. Written every 5 s by
/// FaircopyDaemon, treated as valid for 15 s here.
///
/// It exists so this plugin can tell "the worker is reading the picture right
/// now, it just needs a moment" from "nobody is listening, launch AIGate". The
/// first case must never take the visible road: launching the app is exactly the
/// black flash and the drop to the home screen the daemon was added to remove.
/// KEEP IN SYNC with FaircopyDaemon.heartbeatPath.
static NSString *const kFCDaemonHeartbeatPath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_ocr_daemon.json";

// Our own diagnostics.  A plugin either appears in somebody's menu or it does
// not, and there is no way to tell from the outside which of the three
// managers was involved — so every step writes one line here.
static NSString *const kFCLogPath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_snapper.log";

/// Written only when every route to the picture came up empty: the capture
/// window's own ivars (raw pointers, never messaged) and its view tree.  One
/// file, overwritten each time, so the next version reads facts instead of
/// guessing at which ivar holds the frozen frame.
static NSString *const kFCWindowLogPath = @"/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_snapper_window.log";

static NSString *const kFCPluginIdentifier = @"wiki.qaq.snapper3.plugin.faircopy";
static NSString *const kFCFallbackURL = @"faircopy://ocr";
static NSString *const kFCPluginsDirectory = @"/var/mobile/Library/Snapper3/Plugins";

/// The capture window, remembered at the moment ShellX builds it.
///
/// 3.0.91 went looking for it at tap time and, when the scene enumeration came
/// up empty, walked the object graph instead - which reads weak ivars as if
/// they were plain pointers and killed SpringBoard.
///
/// 3.0.93 held it weakly and the log answered why that is not enough either:
/// the window was remembered at 02:27:06 and already gone at 02:27:14 when the
/// tap arrived. ShellX tears the capture UI down and only then calls the
/// plugin, so a weak reference is nil exactly when it is needed. Holding it
/// strongly costs one window (one frozen frame) at a time and keeps the crop
/// rectangle readable right through the teardown.
static UIWindow *fcCaptureWindow = nil;

/// The crop, taken while the window is provably still alive - at the button
/// tap, a quarter of a second before this plugin is called.  The window itself
/// is retained, so this is belt and braces rather than the only route.
static UIImage *fcLastSelection = nil;

static void FCInstallShellXHooks(void);
static void FCScheduleShellXHookRetry(int remaining);

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

/// The last resort that always has pixels: draw the capture window's own layer.
///
/// Its frozen frame is whatever is on screen minus the dimming rectangles, and
/// those sit outside the selection, so cropping to the selection recovers the
/// original picture at full resolution without knowing where the frame is
/// stored.  Only ever called while the window is still up (button tap).
static UIImage *FCRenderCaptureWindow(id owner)
{
    if (![owner isKindOfClass:[UIView class]])
        return nil;
    UIView *view = (UIView *)owner;
    CGRect rect = view.bounds;
    if (rect.size.width < 8 || rect.size.height < 8)
        return nil;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale > 0 ? [UIScreen mainScreen].scale : 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:rect.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        if (![view drawViewHierarchyInRect:rect afterScreenUpdates:NO])
            [view.layer renderInContext:context.CGContext];
    }];
}

/// The largest picture anywhere below `view`.
///
/// ShellX draws the frozen frame into a plain `UIImageView`, so the view tree
/// is a route to it that needs no ivar read at all - which matters, because
/// the named-ivar route has come back empty twice now while the screenshot is
/// plainly on screen.
static void FCScanForBiggestImage(UIView *view, UIView **bestView, CGFloat *bestArea)
{
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage *image = ((UIImageView *)view).image;
        CGFloat area = image.size.width * image.size.height;
        if (area > 0 && area > *bestArea) {
            *bestArea = area;
            *bestView = view;
        }
    }
    for (UIView *child in view.subviews)
        FCScanForBiggestImage(child, bestView, bestArea);
}

static void FCAppendViewTree(NSMutableString *dump, UIView *view, int depth)
{
    if (depth > 6)
        return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++)
        [pad appendString:@"  "];
    NSString *extra = @"";
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage *image = ((UIImageView *)view).image;
        extra = [NSString stringWithFormat:@" image=%.0fx%.0f", image.size.width, image.size.height];
    }
    [dump appendFormat:@"%@%@ frame=%@%@\n", pad, NSStringFromClass([view class]),
                       NSStringFromCGRect(view.frame), extra];
    for (UIView *child in view.subviews)
        FCAppendViewTree(dump, child, depth + 1);
}

/// Facts, not guesses: every ivar of the capture window with its name, type,
/// offset and (for object types) the raw pointer, plus the view tree below it.
/// Pointers are printed without being messaged - reading a `__weak` ivar as if
/// it were a plain pointer is what killed SpringBoard in 3.0.91.
static void FCDumpCaptureWindow(id owner, NSString *why)
{
    NSMutableString *dump = [NSMutableString string];
    [dump appendFormat:@"== %@ ==\n", why];
    if (!owner) {
        [dump appendString:@"owner: nil\n"];
    } else {
        Class cls = object_getClass(owner);
        [dump appendFormat:@"class: %@\n", NSStringFromClass(cls)];
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *name = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);
            NSString *value = @"-";
            if (type && type[0] == '@')
                value = [NSString stringWithFormat:@"%p",
                         (__bridge void *)object_getIvar(owner, ivar)];
            [dump appendFormat:@"  ivar %-30s %-10s off=%-4ld %@\n",
                               name ?: "?", type ?: "?",
                               (long)ivar_getOffset(ivar), value];
        }
        if (ivars)
            free(ivars);
        if ([owner isKindOfClass:[UIView class]])
            FCAppendViewTree(dump, (UIView *)owner, 0);
    }
    [dump writeToFile:kFCWindowLogPath atomically:YES
            encoding:NSUTF8StringEncoding error:NULL];
    FCLog(@"%@: no picture, window state written", why);
}

/// ShellX's capture window keeps everything we need and hands our plugin
/// nothing: the argument is only an `SSSnapperCropShim` (its `messagingDelegate`
/// answers `displayMessage:` and nothing else).  Five routes, cheapest first,
/// and the last two need no ivar at all - which is the point, since 3.0.94's
/// log showed both named ivars coming back empty while the frame was on screen.
static UIImage *FCImageFromCropOwner(id owner, NSString **explanation)
{
    if (!owner)
        return nil;

    // 1. ShellX's own answer.  `-extractCroppedImage` is the method its
    //    built-in plugins are fed from, so it needs no rectangle arithmetic.
    id extracted = FCPerform(owner, @"extractCroppedImage");
    if ([extracted isKindOfClass:[UIImage class]] && ((UIImage *)extracted).size.width >= 1) {
        if (explanation)
            *explanation = @"extractCroppedImage";
        return extracted;
    }

    // 2. The frozen frame, under the name the class dump gives it.
    UIImage *full = FCReadImageIvar(owner, @"_ssOrigCaptureImage");
    NSString *source = @"_ssOrigCaptureImage";
    if (!full) {
        // The frozen frame is also what the dimming layer draws.
        Ivar ivar = class_getInstanceVariable(object_getClass(owner), "_freezeBgView");
        id view = ivar ? object_getIvar(owner, ivar) : nil;
        if ([view isKindOfClass:[UIImageView class]])
            full = ((UIImageView *)view).image;
        source = @"_freezeBgView";
    }
    // 3. The same frame as a picture in the view tree.
    if (!full && [owner isKindOfClass:[UIView class]]) {
        UIView *bestView = nil;
        CGFloat bestArea = 0;
        FCScanForBiggestImage((UIView *)owner, &bestView, &bestArea);
        if ([bestView isKindOfClass:[UIImageView class]])
            full = ((UIImageView *)bestView).image;
        source = [NSString stringWithFormat:@"view tree %@",
                  bestView ? NSStringFromClass([bestView class]) : @"(no image view)"];
    }
    // 4. Draw the window ourselves and crop that.
    if (!full) {
        full = FCRenderCaptureWindow(owner);
        source = @"window render";
    }
    if (!full) {
        FCDumpCaptureWindow(owner, @"no picture");
        if (explanation)
            *explanation = @"nothing (window state written)";
        return nil;
    }

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
            source, full.size.width, full.size.height,
            NSStringFromCGRect(selection), NSStringFromCGRect(bounds),
            NSStringFromCGRect(crop)];
    }
    return FCCropImage(full, crop);
}

static UIWindow *FCCaptureWindow(void)
{
    if (fcCaptureWindow)
        return fcCaptureWindow;
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

/// Take the crop now, while the window is still up.
static void FCSnapshotSelection(NSString *why)
{
    if (!fcCaptureWindow) {
        FCLog(@"%@: no window to snapshot", why);
        return;
    }
    NSString *explanation = nil;
    UIImage *image = FCImageFromCaptureWindow(&explanation);
    if (!image) {
        FCLog(@"%@: nothing to snapshot", why);
        return;
    }
    fcLastSelection = image;
    FCLog(@"%@: snapshot %.0fx%.0f (%@)",
          why, image.size.width, image.size.height, explanation ?: @"window");
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

/// The resident worker's last heart beat, or nil when there is none readable.
///
/// 3.0.98: kept as a dictionary rather than a BOOL so the log can name the pid
/// and the boot time. A worker in a launchd restart loop looks perfectly alive
/// from the outside — it rewrites this file every time it comes up — and the
/// only way to tell that apart from a healthy one is that its pid and `since`
/// keep changing.
static NSDictionary *FCDaemonHeartbeat(void)
{
    NSData *data = [NSData dataWithContentsOfFile:kFCDaemonHeartbeatPath];
    if (!data)
        return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

/// True while FaircopyDaemon is alive and answering requests (3.0.97).
///
/// A missing or unparsable file means "no worker", which is the safe answer: the
/// caller then takes the visible road, which still works.
static BOOL FCDaemonIsAlive(void)
{
    id stamp = FCDaemonHeartbeat()[@"at"];
    if (![stamp isKindOfClass:[NSNumber class]])
        return NO;
    return ([[NSDate date] timeIntervalSince1970] - [stamp doubleValue]) < 15.0;
}

/// How long to wait before assuming nobody is going to answer.
///
/// 3.0.96: 6 s -> 2 s, because the resident app answered well under a second and
/// the six seconds were dead air in front of a launch the user had already asked
/// for. 3.0.97 keeps the same first look (2 s) but splits the outcome: a live
/// worker gets a much longer grace period before the visible road is taken,
/// because accurate Chinese recognition on a cold model can take a few seconds
/// and launching AIGate on top of a recognition that was about to succeed is the
/// one thing this version is trying to stop.
static void FCArmFallback(void)
{
    FCWatchForResult();
    uint64_t mine = ++fcInvocationSequence;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (fcInvocationSequence != mine)
            return;

        if (FCDaemonIsAlive()) {
            NSDictionary *beat = FCDaemonHeartbeat();
            FCLog(@"no answer in 2s, resident worker is up (pid %@ since %@), waiting for it",
                  beat[@"pid"] ?: @"?", beat[@"since"] ?: @"?");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (fcInvocationSequence != mine)
                    return;
                NSDictionary *now = FCDaemonHeartbeat();
                FCLog(@"still no answer in 8s, opening %@ (worker pid %@ since %@)",
                      kFCFallbackURL, now[@"pid"] ?: @"gone", now[@"since"] ?: @"-");
                FCOpenURL([NSURL URLWithString:kFCFallbackURL]);
            });
            return;
        }

        FCLog(@"no answer in 2s and no resident worker, opening %@", kFCFallbackURL);
        FCOpenURL([NSURL URLWithString:kFCFallbackURL]);
    });
}

#pragma mark - which app is on screen

/// `SBApplication` answers its bundle id under one of these names depending on
/// the release, so all three are tried.
static NSString *FCBundleIDOf(id application)
{
    if (!application)
        return nil;
    for (NSString *key in @[@"bundleIdentifier", @"displayIdentifier", @"applicationIdentifier"]) {
        id value = FCPerform(application, key);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0)
            return value;
    }
    return nil;
}

static BOOL FCPerformBool(id object, NSString *selectorName, BOOL *answered)
{
    *answered = NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector])
        return NO;
    *answered = YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

/// The app the user was looking at when the screenshot was taken.
///
/// This is the whole difference between a panel that opens where the user is
/// and one they only see after going home: AIGate bounces to whatever bundle id
/// sits in `faircopy_ocr_target.txt`, and with no target it falls back to
/// "whoever opened me" — SpringBoard, because the launch comes from here.
/// SpringBoard's own answer to "who is in front" is private and has moved
/// between releases, so every plausible spelling is tried and the winner is
/// logged: one build then says which one this iOS honours.
static NSString *FCFrontmostBundleIdentifier(void)
{
    NSString *answer = nil;

    // 1. +[SBApplication frontmostApplication]
    answer = FCBundleIDOf(FCPerform(NSClassFromString(@"SBApplication"), @"frontmostApplication"));
    if (answer.length > 0) {
        FCLog(@"front app via SBApplication = %@", answer);
        return answer;
    }

    // 2. -[SBApplicationController sharedInstance].frontmostApplication
    id controller = FCPerform(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
    answer = FCBundleIDOf(FCPerform(controller, @"frontmostApplication"));
    if (answer.length > 0) {
        FCLog(@"front app via SBApplicationController = %@", answer);
        return answer;
    }

    // 3. the workspace knows it too, under either spelling
    id workspace = FCPerform(NSClassFromString(@"SBWorkspace"), @"mainWorkspace");
    if (!workspace)
        workspace = FCPerform(NSClassFromString(@"SBMainWorkspace"), @"sharedInstance");
    if (!workspace)
        workspace = FCPerform(NSClassFromString(@"SBMainWorkspace"), @"mainWorkspace");
    answer = FCBundleIDOf(FCPerform(workspace, @"frontmostApplication"));
    if (answer.length > 0) {
        FCLog(@"front app via %@ = %@", NSStringFromClass([workspace class]), answer);
        return answer;
    }

    // 4. SpringBoard is an application too; some releases answer there.
    answer = FCBundleIDOf(FCPerform(UIApplication.sharedApplication, @"frontmostApplication"));
    if (answer.length > 0) {
        FCLog(@"front app via UIApplication = %@", answer);
        return answer;
    }

    // 5. ask every application whether it is the frontmost one.
    id applications = FCPerform(controller, @"allApplications");
    if ([applications isKindOfClass:[NSArray class]]) {
        for (id candidate in (NSArray *)applications) {
            BOOL answered = NO;
            if (FCPerformBool(candidate, @"isFrontmostApplication", &answered) && answered) {
                answer = FCBundleIDOf(candidate);
                if (answer.length > 0) {
                    FCLog(@"front app via isFrontmostApplication = %@", answer);
                    return answer;
                }
            }
        }
    }

    FCLog(@"front app: no probe answered, the panel will arbitrate");
    return nil;
}

static void FCHandOffImage(UIImage *image, NSString *source)
{
    if (![image isKindOfClass:[UIImage class]] || image.size.width < 1 || image.size.height < 1) {
        FCLog(@"%@: no usable picture", source);
        return;
    }
    FCLog(@"%@: picture %.0fx%.0f", source, image.size.width, image.size.height);

    // Asked here, on the caller's thread: SpringBoard's application tables
    // belong to the main run loop, and this is where every entry point already
    // runs. The answer travels into the background block so the write order is
    // "picture, then target, then notify".
    NSString *displayTarget = FCFrontmostBundleIdentifier();
    FCLog(@"%@: display target %@", source, displayTarget ?: @"none");

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
            // The target is written together with the picture, never left over
            // from an earlier call: AIGate deletes it after every hand-off, and
            // a stale one would send the panel to an app that is no longer on
            // screen. Without a target AIGate bounces to SpringBoard (the
            // launcher), the panel is summoned on the home screen, and the user
            // is thrown out of the app they were reading.
            if (displayTarget.length > 0) {
                [displayTarget writeToFile:kFCDisplayTargetPath atomically:YES
                                encoding:NSUTF8StringEncoding error:NULL];
            } else {
                [manager removeItemAtPath:kFCDisplayTargetPath error:NULL];
            }
            // 「Faircopy 翻译」 means translate: the panel opens already running
            // the translation task instead of showing word chips.
            [kFCModeTranslate writeToFile:kFCModePath atomically:YES
                              encoding:NSUTF8StringEncoding error:NULL];

            FCLog(@"%@: handed off %lu bytes, mode=%@", source, (unsigned long)data.length,
                  kFCModeTranslate);
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
    FCLog(@"menu action from %@, snap %@, remembered window %@",
          NSStringFromClass([action class]), NSStringFromClass([snap class]),
          fcCaptureWindow ? NSStringFromClass([fcCaptureWindow class]) : @"none");
    UIImage *image = FCImageFromSnap(snap);
    if (!image) {
        NSString *explanation = nil;
        image = FCImageFromCaptureWindow(&explanation);
        FCLog(@"menu action: snap gave nothing, window gave %@", explanation ?: @"nothing");
    }
    if (!image)
        image = fcLastSelection;
    FCHandOffImage(image, @"menu");
    fcLastSelection = nil;
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
    // Logged before anything is read, so that "tapped and nothing happened" can
    // never again mean "no line at all" - 3.0.91's log stopped right here.
    FCLog(@"action bar action from %@, remembered window %@",
          NSStringFromClass([action class]),
          fcCaptureWindow ? NSStringFromClass([fcCaptureWindow class]) : @"none");

    NSString *explanation = nil;
    UIImage *image = FCImageFromCaptureWindow(&explanation);
    if (!image) {
        // The shim's messaging delegate is the only other thing that could
        // carry the frame, and looking at it costs nothing.
        image = FCImageFromCropOwner(FCPerform(action, @"messagingDelegate"), &explanation);
    }
    if (!image && fcLastSelection) {
        image = fcLastSelection;
        explanation = @"snapshot taken at the button tap";
    }
    if (!image) {
        FCDumpGraph(action);
        FCLog(@"action bar action from %@: no picture anywhere, graph dumped",
              NSStringFromClass([action class]));
        return;
    }
    FCLog(@"action bar action: %@", explanation ?: @"window");
    FCHandOffImage(image, @"action bar");
    fcLastSelection = nil;
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

@interface SSAreaCaptureRootViewController : UIViewController
@end

@interface NSObject (FaircopySnapperWindow)
- (id)pluginForId:(NSString *)identifier;
@end

#pragma mark - Snapper3 side

%group FaircopySnapper

%hook Snapper3PluginManager

- (id)init
{
    id manager = %orig;
    FCAdoptSnapperProtocol();
    FCRegisterIntoManager(manager, @"init");
    FCInstallShellXHooks();
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
    // ScreenshotShell registers its own plugins through exactly this method, so
    // by the time one of them arrives its classes are loaded and the ShellX
    // hooks can finally be installed.
    FCInstallShellXHooks();
}

%end

%end

#pragma mark - ShellX side

%group FaircopySnapperShellX

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

/// Remember the window the moment it exists.  Both initialisers are hooked
/// because the class implements both, and `-showActions` refreshes the pointer
/// in the one case the hooks could have been late for: a window that was
/// already built before these hooks were installed.
- (id)initWithWindowScene:(UIWindowScene *)scene
{
    id window = %orig;
    if ([window isKindOfClass:[UIWindow class]]) {
        fcCaptureWindow = (UIWindow *)window;
        FCLog(@"capture window created with a scene: %@",
              NSStringFromClass([window class]));
    }
    return window;
}

- (id)initWithFrame:(CGRect)frame
{
    id window = %orig;
    if ([window isKindOfClass:[UIWindow class]]) {
        fcCaptureWindow = (UIWindow *)window;
        FCLog(@"capture window created with a frame: %@",
              NSStringFromClass([window class]));
    }
    return window;
}

/// One line of ground truth: whatever ShellX hands its own plugins, taken from
/// the same method, at the same instant.  If this prints a size while our
/// snapshot path still finds nothing, the fault is in our reads, not in the
/// timing.
- (id)extractCroppedImage
{
    id image = %orig;
    if ([image isKindOfClass:[UIImage class]]) {
        UIImage *picture = (UIImage *)image;
        FCLog(@"extractCroppedImage -> %.0fx%.0f",
              picture.size.width, picture.size.height);
    } else {
        FCLog(@"extractCroppedImage -> %@",
              image ? NSStringFromClass([image class]) : @"nil");
    }
    return image;
}

- (void)showActions
{
    if (!fcCaptureWindow && [self isKindOfClass:[UIWindow class]])
        fcCaptureWindow = (UIWindow *)self;
    // The menu only appears once the selection exists, so this is a good
    // moment for a snapshot; the tap itself is an even better one.
    FCSnapshotSelection(@"showActions");
    %orig;
    FCLog(@"showActions: window %@", fcCaptureWindow ? @"held" : @"missing");
}

/// The menu asks for a plugin by identifier before it can draw the button, so
/// one line here answers "is our entry really in this menu" without guessing.
- (id)pluginForId:(NSString *)identifier
{
    id plugin = %orig;
    if ([identifier isEqualToString:kFCPluginIdentifier])
        FCLog(@"pluginForId: %@ -> %@", identifier,
              plugin ? NSStringFromClass([plugin class]) : @"nil");
    return plugin;
}

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
    // The last moment the capture window is certainly still alive: the 3.0.93
    // log has it gone 250 ms later, when the plugin itself is called.
    FCSnapshotSelection(@"plugin button tap");
    %orig;
    FCLog(@"pluginActionBtnTapped: done");
}

%end

%hook SSAreaCaptureRootViewController

- (void)viewDidLoad
{
    %orig;
    UIWindow *window = self.view.window;
    if (window) {
        fcCaptureWindow = window;
        FCLog(@"capture root view controller gave the window: %@",
              NSStringFromClass([window class]));
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    UIWindow *window = self.view.window;
    if (window) {
        fcCaptureWindow = window;
        FCLog(@"capture UI appeared in %@", NSStringFromClass([window class]));
    }
}

%end

%end

static BOOL fcShellXHooksInstalled = NO;

/// Logos installs a group's hooks only when it is told to, and it installs
/// nothing at all for a class that does not exist yet.  ScreenshotShell is not
/// in the room when this image loads - every log so far starts with
/// `loaded: snapper=1 shellx=0` - so everything ShellX-side (the capture
/// window, the menu lookups, the plugin manager) was dead code from 3.0.90 to
/// 3.0.92.  Installing the group again once the class is up is the fix.
static void FCInstallShellXHooks(void)
{
    if (fcShellXHooksInstalled)
        return;
    if (!NSClassFromString(@"SSAreaCaptureWindow"))
        return;

    fcShellXHooksInstalled = YES;
    %init(FaircopySnapperShellX);
    FCLog(@"shellx hooks installed: window=%@ manager=%@",
          NSClassFromString(@"SSAreaCaptureWindow") ? @"yes" : @"no",
          NSClassFromString(@"SHELLXPluginManager") ? @"yes" : @"no");
}

/// ScreenshotShell loads seconds after SpringBoard does, so one attempt at
/// constructor time is not enough and a single fixed delay would be a guess.
/// This polls until the class appears, then stops for good.
static void FCScheduleShellXHookRetry(int remaining)
{
    if (fcShellXHooksInstalled || remaining <= 0)
        return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FCInstallShellXHooks();
        FCScheduleShellXHookRetry(remaining - 1);
    });
}

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
        FCInstallShellXHooks();
        FCScheduleShellXHookRetry(300);
    }
}
