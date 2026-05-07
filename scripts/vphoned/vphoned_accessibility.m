/*
 * vphoned_accessibility — Accessibility tree query.
 *
 * Developer model:
 *   - The guest daemon cannot see pixels semantically; OCR is intentionally not
 *     used here.
 *   - iOS keeps semantic UI data behind AXRuntime / AccessibilityUtilities.
 *   - AXElementFetcher needs an explicit current application in daemon context;
 *     relying on SpringBoard/frontmost APIs is not stable on the research VM.
 *
 * Therefore the command accepts pid or bundle_id, creates an AXElement for that
 * application, feeds it to AXElementFetcher, and serializes the returned
 * accessible elements.  If no target is supplied we try a best-effort foreground
 * lookup and finally fall back to a single running user app candidate.
 */

#import "vphoned_accessibility.h"
#import "vphoned_protocol.h"

#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <math.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sys/time.h>
#include <unistd.h>

// MARK: - Private API state

static BOOL gAXLoadAttempted = NO;
static BOOL gAXAvailable = NO;
static Class gAXElementClass = Nil;
static Class gAXUIElementClass = Nil;
static Class gAXElementFetcherClass = Nil;
static Class gFBSSystemServiceClass = Nil;
static Class gLSApplicationWorkspaceClass = Nil;

typedef void (*AXSetBoolFn)(Boolean enabled);
typedef Boolean (*AXGetBoolFn)(void);
typedef CFStringRef (*SBSCopyFrontmostFn)(mach_port_t port);
typedef mach_port_t (*SBSSpringBoardServerPortFn)(void);

// MARK: - objc_msgSend helpers

static id vp_msg_id0(id target, SEL sel) {
  return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static id vp_msg_id1(id target, SEL sel, id arg) {
  return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
}

static id vp_msg_id_uint(id target, SEL sel, NSUInteger arg) {
  return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(target, sel, arg);
}

static id vp_msg_id_int(id target, SEL sel, int arg) {
  return ((id (*)(id, SEL, int))objc_msgSend)(target, sel, arg);
}

static void vp_msg_void1(id target, SEL sel, id arg) {
  ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
}

static BOOL vp_msg_bool1(id target, SEL sel, BOOL arg) {
  return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(target, sel, arg);
}

static BOOL vp_obj_responds(id obj, const char *name) {
  if (!obj)
    return NO;
  return [obj respondsToSelector:sel_registerName(name)];
}

// MARK: - Generic helpers

static double vp_now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return ((double)tv.tv_sec * 1000.0) + ((double)tv.tv_usec / 1000.0);
}

static NSNumber *vp_number_from_msg(NSDictionary *msg, NSString *key) {
  id value = msg[key];
  if ([value isKindOfClass:[NSNumber class]])
    return value;
  if ([value isKindOfClass:[NSString class]]) {
    double d = [(NSString *)value doubleValue];
    if (isfinite(d))
      return @(d);
  }
  return nil;
}

static int vp_int_from_msg(NSDictionary *msg, NSString *key, int fallback) {
  NSNumber *n = vp_number_from_msg(msg, key);
  return n ? [n intValue] : fallback;
}

static double vp_double_from_msg(NSDictionary *msg, NSString *key,
                                 double fallback) {
  NSNumber *n = vp_number_from_msg(msg, key);
  return n ? [n doubleValue] : fallback;
}

static NSString *vp_safe_string_value(id value) {
  if (!value || value == (id)kCFNull)
    return nil;
  if ([value isKindOfClass:[NSString class]])
    return (NSString *)value;
  if ([value isKindOfClass:[NSNumber class]])
    return [(NSNumber *)value stringValue];
  if ([value respondsToSelector:@selector(description)])
    return [value description];
  return nil;
}

static NSString *vp_ax_string(id element, const char *selectorName) {
  if (!vp_obj_responds(element, selectorName))
    return nil;
  @try {
    id value = vp_msg_id0(element, sel_registerName(selectorName));
    return vp_safe_string_value(value);
  } @catch (NSException *e) {
    return nil;
  }
}

static NSNumber *vp_ax_int(id element, const char *selectorName) {
  if (!vp_obj_responds(element, selectorName))
    return nil;
  @try {
    int value = ((int (*)(id, SEL))objc_msgSend)(
        element, sel_registerName(selectorName));
    return @(value);
  } @catch (NSException *e) {
    return nil;
  }
}

static NSNumber *vp_ax_uint64(id element, const char *selectorName) {
  if (!vp_obj_responds(element, selectorName))
    return nil;
  @try {
    uint64_t value = ((uint64_t (*)(id, SEL))objc_msgSend)(
        element, sel_registerName(selectorName));
    return @(value);
  } @catch (NSException *e) {
    return nil;
  }
}

static NSNumber *vp_ax_bool(id element, const char *selectorName) {
  if (!vp_obj_responds(element, selectorName))
    return nil;
  @try {
    BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(
        element, sel_registerName(selectorName));
    return @(value);
  } @catch (NSException *e) {
    return nil;
  }
}

static BOOL vp_rect_is_sane(CGRect rect) {
  return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
         isfinite(rect.size.width) && isfinite(rect.size.height) &&
         fabs(rect.origin.x) < 1000000.0 && fabs(rect.origin.y) < 1000000.0 &&
         fabs(rect.size.width) < 1000000.0 &&
         fabs(rect.size.height) < 1000000.0;
}

static BOOL vp_ax_rect(id element, const char *selectorName, CGRect *outRect) {
  if (!vp_obj_responds(element, selectorName))
    return NO;
  @try {
    CGRect rect = ((CGRect (*)(id, SEL))objc_msgSend)(
        element, sel_registerName(selectorName));
    if (!vp_rect_is_sane(rect))
      return NO;
    if (outRect)
      *outRect = rect;
    return YES;
  } @catch (NSException *e) {
    return NO;
  }
}

static NSDictionary *vp_rect_dict(CGRect rect) {
  return @{
    @"x" : @(rect.origin.x),
    @"y" : @(rect.origin.y),
    @"width" : @(rect.size.width),
    @"height" : @(rect.size.height),
    @"max_x" : @(CGRectGetMaxX(rect)),
    @"max_y" : @(CGRectGetMaxY(rect)),
  };
}

static NSDictionary *vp_point_dict(CGPoint point) {
  return @{@"x" : @(point.x), @"y" : @(point.y)};
}

static CGRect vp_scale_rect(CGRect rect, double scaleX, double scaleY) {
  return CGRectMake(rect.origin.x * scaleX, rect.origin.y * scaleY,
                    rect.size.width * scaleX, rect.size.height * scaleY);
}

// MARK: - Private framework loading

static void vp_ax_enable_preferences(void) {
  // These settings make third-party app accessibility trees available without
  // requiring VoiceOver UI to be enabled.  Missing symbols are fine on older OSes.
  AXSetBoolFn setAppAX =
      (AXSetBoolFn)dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
  AXSetBoolFn setGeneric = (AXSetBoolFn)dlsym(
      RTLD_DEFAULT, "_AXSSetGenericAccessibilityClientEnabled");
  AXSetBoolFn setAutomation =
      (AXSetBoolFn)dlsym(RTLD_DEFAULT, "_AXSSetAutomationEnabled");

  if (setAppAX)
    setAppAX(1);
  if (setGeneric)
    setGeneric(1);
  if (setAutomation)
    setAutomation(1);
}

static BOOL vp_ax_load(void) {
  if (gAXLoadAttempted)
    return gAXAvailable;
  gAXLoadAttempted = YES;

  void *axRuntime = dlopen(
      "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
      RTLD_NOW | RTLD_GLOBAL);
  if (!axRuntime)
    NSLog(@"vphoned: dlopen AXRuntime failed: %s", dlerror());

  void *axUtils = dlopen("/System/Library/PrivateFrameworks/"
                         "AccessibilityUtilities.framework/"
                         "AccessibilityUtilities",
                         RTLD_NOW | RTLD_GLOBAL);
  if (!axUtils)
    NSLog(@"vphoned: dlopen AccessibilityUtilities failed: %s", dlerror());

  void *fbs = dlopen("/System/Library/PrivateFrameworks/"
                     "FrontBoardServices.framework/FrontBoardServices",
                     RTLD_LAZY | RTLD_GLOBAL);
  if (!fbs)
    NSLog(@"vphoned: dlopen FrontBoardServices for AX failed: %s", dlerror());

  void *sbs = dlopen("/System/Library/PrivateFrameworks/"
                     "SpringBoardServices.framework/SpringBoardServices",
                     RTLD_LAZY | RTLD_GLOBAL);
  if (!sbs)
    NSLog(@"vphoned: dlopen SpringBoardServices for AX failed: %s", dlerror());

  gAXElementClass = NSClassFromString(@"AXElement");
  gAXUIElementClass = NSClassFromString(@"AXUIElement");
  gAXElementFetcherClass = NSClassFromString(@"AXElementFetcher");
  gFBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
  gLSApplicationWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");

  gAXAvailable = axRuntime && axUtils && gAXElementClass && gAXUIElementClass &&
                 gAXElementFetcherClass;
  if (gAXAvailable)
    vp_ax_enable_preferences();

  NSLog(@"vphoned: accessibility %@ (AXElement=%s AXUIElement=%s fetcher=%s)",
        gAXAvailable ? @"loaded" : @"unavailable",
        gAXElementClass ? "yes" : "no", gAXUIElementClass ? "yes" : "no",
        gAXElementFetcherClass ? "yes" : "no");
  return gAXAvailable;
}

BOOL vp_accessibility_available(void) { return vp_ax_load(); }

// MARK: - App target resolution

static id vp_fbs_shared_service(void) {
  if (!gFBSSystemServiceClass)
    return nil;
  @try {
    return vp_msg_id0((id)gFBSSystemServiceClass, sel_registerName("sharedService"));
  } @catch (NSException *e) {
    return nil;
  }
}

static pid_t vp_pid_for_bundle(NSString *bundleID) {
  if (bundleID.length == 0)
    return 0;
  id service = vp_fbs_shared_service();
  if (!service || !vp_obj_responds(service, "pidForApplication:"))
    return 0;
  @try {
    return ((pid_t (*)(id, SEL, id))objc_msgSend)(
        service, sel_registerName("pidForApplication:"), bundleID);
  } @catch (NSException *e) {
    return 0;
  }
}

static NSArray *vp_installed_app_proxies(void) {
  if (!gLSApplicationWorkspaceClass)
    return @[];
  @try {
    id ws = vp_msg_id0((id)gLSApplicationWorkspaceClass,
                       sel_registerName("defaultWorkspace"));
    if (!ws || !vp_obj_responds(ws, "allInstalledApplications"))
      return @[];
    id apps = vp_msg_id0(ws, sel_registerName("allInstalledApplications"));
    return [apps isKindOfClass:[NSArray class]] ? apps : @[];
  } @catch (NSException *e) {
    return @[];
  }
}

static NSString *vp_proxy_string(id proxy, const char *selectorName) {
  if (!vp_obj_responds(proxy, selectorName))
    return nil;
  @try {
    return vp_safe_string_value(vp_msg_id0(proxy, sel_registerName(selectorName)));
  } @catch (NSException *e) {
    return nil;
  }
}

static NSDictionary *vp_app_info_for_pid(pid_t pid) {
  if (pid <= 0)
    return nil;
  for (id proxy in vp_installed_app_proxies()) {
    NSString *bundleID = vp_proxy_string(proxy, "bundleIdentifier");
    if (bundleID.length == 0)
      continue;
    if (vp_pid_for_bundle(bundleID) == pid) {
      NSString *name = vp_proxy_string(proxy, "localizedName") ?: @"";
      NSString *type = vp_proxy_string(proxy, "applicationType") ?: @"";
      return @{@"bundle_id" : bundleID, @"name" : name, @"type" : type,
               @"pid" : @(pid)};
    }
  }
  return nil;
}

static NSString *vp_frontmost_bundle_sbs(void) {
  SBSCopyFrontmostFn copyFrontmost = (SBSCopyFrontmostFn)dlsym(
      RTLD_DEFAULT, "SBSCopyFrontmostApplicationDisplayIdentifier");
  if (!copyFrontmost)
    return nil;

  mach_port_t port = 0;
  SBSSpringBoardServerPortFn portFn = (SBSSpringBoardServerPortFn)dlsym(
      RTLD_DEFAULT, "SBSSpringBoardServerPort");
  if (portFn)
    port = portFn();

  CFStringRef value = NULL;
  @try {
    value = copyFrontmost(port);
  } @catch (NSException *e) {
    value = NULL;
  }
  if (!value)
    return nil;
  NSString *bundleID = [(__bridge NSString *)value copy];
  CFRelease(value);
  return bundleID.length > 0 ? bundleID : nil;
}

static NSNumber *vp_focused_pid_axspringboard(void) {
  Class axSB = NSClassFromString(@"AXSpringBoardServer");
  if (!axSB)
    return nil;
  @try {
    id server = vp_msg_id0((id)axSB, sel_registerName("server"));
    if (!server)
      return nil;
    if (vp_obj_responds(server, "focusedAppPID")) {
      id focused = vp_msg_id0(server, sel_registerName("focusedAppPID"));
      if ([focused isKindOfClass:[NSNumber class]] && [focused intValue] > 0)
        return focused;
    }
    if (vp_obj_responds(server, "nativeFocusedApplication")) {
      int pid = ((int (*)(id, SEL))objc_msgSend)(
          server, sel_registerName("nativeFocusedApplication"));
      if (pid > 0)
        return @(pid);
    }
  } @catch (NSException *e) {
    return nil;
  }
  return nil;
}

static NSArray *vp_running_user_app_candidates(void) {
  NSMutableArray *candidates = [NSMutableArray array];
  for (id proxy in vp_installed_app_proxies()) {
    NSString *bundleID = vp_proxy_string(proxy, "bundleIdentifier");
    if (bundleID.length == 0)
      continue;
    pid_t pid = vp_pid_for_bundle(bundleID);
    if (pid <= 0)
      continue;
    NSString *type = vp_proxy_string(proxy, "applicationType") ?: @"";
    if ([type isEqualToString:@"System"])
      continue;
    NSString *name = vp_proxy_string(proxy, "localizedName") ?: @"";
    [candidates addObject:@{
      @"bundle_id" : bundleID,
      @"name" : name,
      @"type" : type,
      @"pid" : @(pid),
    }];
  }
  return candidates;
}

static NSMutableDictionary *vp_resolve_target(NSDictionary *msg) {
  NSString *bundleID = msg[@"bundle_id"] ?: msg[@"bundle"];
  NSNumber *pidNumber = vp_number_from_msg(msg, @"pid");
  pid_t pid = pidNumber ? [pidNumber intValue] : 0;
  NSString *source = @"request";

  if (pid <= 0 && bundleID.length > 0) {
    pid = vp_pid_for_bundle(bundleID);
    source = @"bundle_id";
  }

  if (pid <= 0 && bundleID.length == 0) {
    NSString *frontmost = vp_frontmost_bundle_sbs();
    if (frontmost.length > 0) {
      bundleID = frontmost;
      pid = vp_pid_for_bundle(bundleID);
      source = @"frontmost_sbs";
    }
  }

  if (pid <= 0 && bundleID.length == 0) {
    NSNumber *focusedPID = vp_focused_pid_axspringboard();
    if (focusedPID && [focusedPID intValue] > 0) {
      pid = [focusedPID intValue];
      source = @"focused_axspringboard";
    }
  }

  if (pid <= 0 && bundleID.length == 0) {
    NSArray *candidates = vp_running_user_app_candidates();
    if (candidates.count == 1) {
      NSDictionary *candidate = candidates.firstObject;
      bundleID = candidate[@"bundle_id"];
      pid = [candidate[@"pid"] intValue];
      source = @"single_running_user_app";
    } else if (candidates.count > 1) {
      NSMutableDictionary *err = [NSMutableDictionary dictionary];
      err[@"error"] = @"multiple running user apps; pass bundle_id or pid";
      err[@"candidates"] = candidates;
      return err;
    }
  }

  if (pid <= 0) {
    NSMutableDictionary *err = [NSMutableDictionary dictionary];
    err[@"error"] = bundleID.length > 0
                        ? [NSString stringWithFormat:@"app is not running: %@",
                                                   bundleID]
                        : @"missing target; pass bundle_id or pid";
    NSArray *candidates = vp_running_user_app_candidates();
    if (candidates.count > 0)
      err[@"candidates"] = candidates;
    return err;
  }

  NSDictionary *appInfo = vp_app_info_for_pid(pid);
  if (bundleID.length == 0)
    bundleID = appInfo[@"bundle_id"];
  NSString *name = appInfo[@"name"] ?: @"";

  return [@{
    @"pid" : @(pid),
    @"bundle_id" : bundleID ?: @"",
    @"name" : name,
    @"source" : source,
  } mutableCopy];
}

// MARK: - AX fetch / serialization

static id vp_ax_application_element(pid_t pid) {
  if (pid <= 0 || !gAXUIElementClass || !gAXElementClass)
    return nil;
  @try {
    id uiElement = vp_msg_id_int((id)gAXUIElementClass,
                                 sel_registerName("uiApplicationWithPid:"),
                                 pid);
    if (!uiElement)
      return nil;
    id element = vp_msg_id1((id)gAXElementClass,
                            sel_registerName("elementWithUIElement:"),
                            uiElement);
    return element;
  } @catch (NSException *e) {
    NSLog(@"vphoned: AX application element failed: %@", e);
    return nil;
  }
}

static id vp_ax_new_fetcher(void) {
  if (!gAXElementFetcherClass)
    return nil;
  @try {
    SEL initSel = sel_registerName("initWithDelegate:fetchEvents:"
                                   "enableEventManagement:enableGrouping:"
                                   "shouldIncludeNonScannerElements:beginEnabled:");
    id alloc = [gAXElementFetcherClass alloc];
    return ((id (*)(id, SEL, id, uint64_t, BOOL, BOOL, BOOL, BOOL))objc_msgSend)(
        alloc, initSel, nil, 0, NO, NO, YES, YES);
  } @catch (NSException *e) {
    NSLog(@"vphoned: AXElementFetcher init failed: %@", e);
    return nil;
  }
}

static NSArray *vp_ax_fetch_elements(id appElement) {
  if (!appElement)
    return nil;
  id fetcher = vp_ax_new_fetcher();
  if (!fetcher)
    return nil;

  @try {
    if (vp_obj_responds(fetcher, "setCurrentApps:"))
      vp_msg_void1(fetcher, sel_registerName("setCurrentApps:"), @[ appElement ]);
    vp_msg_void1(fetcher, sel_registerName("_setCurrentApplications:"),
                 @[ appElement ]);
    BOOL fetched = vp_msg_bool1(fetcher, sel_registerName("_fetchElements:"), NO);
    if (!fetched)
      fetched = vp_msg_bool1(fetcher, sel_registerName("_fetchElements:"), YES);
    id elements = vp_msg_id0(fetcher, sel_registerName("availableElements"));
    if ([elements isKindOfClass:[NSArray class]])
      return elements;
  } @catch (NSException *e) {
    NSLog(@"vphoned: AX fetch failed: %@", e);
  }
  return nil;
}

static NSArray *vp_ax_fetch_elements_with_timeout(id appElement, int timeoutMs,
                                                  BOOL *timedOut) {
  if (timedOut)
    *timedOut = NO;
  if (timeoutMs <= 0)
    return vp_ax_fetch_elements(appElement);

  __block NSArray *elements = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      elements = vp_ax_fetch_elements(appElement);
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC);
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    if (timedOut)
      *timedOut = YES;
    NSLog(@"vphoned: AXElementFetcher timed out after %dms", timeoutMs);
    return nil;
  }
  return elements;
}

static NSArray *vp_ax_array_from_selector(id element, const char *selectorName) {
  if (!element || !vp_obj_responds(element, selectorName))
    return nil;
  @try {
    id value = vp_msg_id0(element, sel_registerName(selectorName));
    return [value isKindOfClass:[NSArray class]] ? value : nil;
  } @catch (NSException *e) {
    NSLog(@"vphoned: AX selector %s failed: %@", selectorName, e);
    return nil;
  }
}

static NSArray *vp_ax_array_from_selector_with_count(id element,
                                                     const char *selectorName,
                                                     NSUInteger count) {
  if (!element || !vp_obj_responds(element, selectorName))
    return nil;
  @try {
    id value = vp_msg_id_uint(element, sel_registerName(selectorName), count);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
  } @catch (NSException *e) {
    NSLog(@"vphoned: AX selector %s failed: %@", selectorName, e);
    return nil;
  }
}

static NSArray *vp_ax_array_with_timeout(id element, const char *selectorName,
                                         int timeoutMs, BOOL *timedOut) {
  if (timedOut)
    *timedOut = NO;
  if (timeoutMs <= 0)
    return vp_ax_array_from_selector(element, selectorName);

  __block NSArray *elements = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      elements = vp_ax_array_from_selector(element, selectorName);
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC);
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    if (timedOut)
      *timedOut = YES;
    NSLog(@"vphoned: AX selector %s timed out after %dms", selectorName,
          timeoutMs);
    return nil;
  }
  return elements;
}

static NSArray *vp_ax_array_with_count_timeout(id element,
                                               const char *selectorName,
                                               NSUInteger count,
                                               int timeoutMs,
                                               BOOL *timedOut) {
  if (timedOut)
    *timedOut = NO;
  if (timeoutMs <= 0)
    return vp_ax_array_from_selector_with_count(element, selectorName, count);

  __block NSArray *elements = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      elements = vp_ax_array_from_selector_with_count(element, selectorName,
                                                      count);
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC);
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    if (timedOut)
      *timedOut = YES;
    NSLog(@"vphoned: AX selector %s timed out after %dms", selectorName,
          timeoutMs);
    return nil;
  }
  return elements;
}

static NSString *vp_ax_element_key(id element) {
  if (!element)
    return nil;
  NSNumber *pid = vp_ax_int(element, "pid") ?: @(0);
  NSNumber *traits = vp_ax_uint64(element, "traits") ?: @(0);
  NSString *label = vp_ax_string(element, "label") ?: @"";
  NSString *identifier = vp_ax_string(element, "axIdentifier") ?:
                         vp_ax_string(element, "identifier") ?: @"";
  CGRect frame = CGRectZero;
  BOOL hasFrame = vp_ax_rect(element, "frame", &frame);
  if (hasFrame) {
    return [NSString
        stringWithFormat:@"%@:%@:%@:%@:%0.2f:%0.2f:%0.2f:%0.2f", pid, traits,
                         label, identifier, frame.origin.x, frame.origin.y,
                         frame.size.width, frame.size.height];
  }
  return [NSString stringWithFormat:@"%@:%@:%@:%@:%p", pid, traits, label,
                                    identifier, element];
}

static void vp_ax_append_unique(NSMutableArray *out, NSMutableSet *seen,
                                NSArray *elements, NSUInteger maxNodes) {
  if (![elements isKindOfClass:[NSArray class]])
    return;
  for (id element in elements) {
    if (out.count >= maxNodes)
      return;
    if (!element)
      continue;
    NSString *key = vp_ax_element_key(element);
    if (key.length > 0 && [seen containsObject:key])
      continue;
    if (key.length > 0)
      [seen addObject:key];
    [out addObject:element];
  }
}

static NSArray *vp_ax_fetch_elements_manual(id appElement, NSUInteger maxNodes,
                                            int timeoutMs,
                                            NSString **sourceOut) {
  if (!appElement)
    return nil;

  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  NSString *appKey = vp_ax_element_key(appElement);
  if (appKey.length > 0)
    [seen addObject:appKey];

  int perSelectorTimeout = timeoutMs > 0 ? MIN(MAX(timeoutMs / 3, 500), 2500) : 0;
  const char *selectors[] = {
      "visibleElements",
      "accessibleDescendants",
      "explorerElements",
      "nativeFocusableElements",
      "children",
  };

  for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
    BOOL timedOut = NO;
    NSArray *elements =
        vp_ax_array_with_timeout(appElement, selectors[i], perSelectorTimeout,
                                 &timedOut);
    if (elements.count > 0) {
      vp_ax_append_unique(out, seen, elements, maxNodes);
      if (sourceOut)
        *sourceOut = [NSString stringWithFormat:@"manual_%s", selectors[i]];
      if (out.count > 0)
        return out;
    }
  }

  BOOL timedOut = NO;
  NSArray *next =
      vp_ax_array_with_count_timeout(appElement, "nextElementsWithCount:",
                                     maxNodes, perSelectorTimeout, &timedOut);
  if (next.count > 0) {
    vp_ax_append_unique(out, seen, next, maxNodes);
    if (sourceOut)
      *sourceOut = @"manual_nextElementsWithCount";
    return out;
  }

  return out.count > 0 ? out : nil;
}

static NSMutableDictionary *vp_ax_node(id element, NSInteger nodeID,
                                       NSString *roleOverride,
                                       double scaleX, double scaleY) {
  NSMutableDictionary *node = [NSMutableDictionary dictionary];
  node[@"id"] = @(nodeID);
  node[@"class"] = element ? @(object_getClassName(element)) : @"";

  NSString *label = vp_ax_string(element, "label");
  NSString *value = vp_ax_string(element, "value");
  NSString *hint = vp_ax_string(element, "hint");
  NSString *identifier = vp_ax_string(element, "identifier");
  NSString *axIdentifier = vp_ax_string(element, "axIdentifier");
  NSString *bundleID = vp_ax_string(element, "bundleId");
  NSString *role = roleOverride ?: vp_ax_string(element, "roleDescription");

  if (label.length > 0)
    node[@"label"] = label;
  if (value.length > 0)
    node[@"value"] = value;
  if (hint.length > 0)
    node[@"hint"] = hint;
  if (identifier.length > 0)
    node[@"identifier"] = identifier;
  if (axIdentifier.length > 0)
    node[@"ax_identifier"] = axIdentifier;
  if (bundleID.length > 0)
    node[@"bundle_id"] = bundleID;
  if (role.length > 0)
    node[@"role"] = role;

  NSNumber *pid = vp_ax_int(element, "pid");
  NSNumber *traits = vp_ax_uint64(element, "traits");
  NSNumber *visible = vp_ax_bool(element, "isVisible");
  NSNumber *accessible = vp_ax_bool(element, "isAccessibleElement");
  NSNumber *interactable = vp_ax_bool(element, "respondsToUserInteraction");
  NSNumber *focused = vp_ax_bool(element, "isNativeFocused");
  NSNumber *hasTextEntry = vp_ax_bool(element, "hasTextEntry");

  if (pid)
    node[@"pid"] = pid;
  if (traits)
    node[@"traits"] = traits;
  if (visible)
    node[@"visible"] = visible;
  if (accessible)
    node[@"accessible"] = accessible;
  if (interactable)
    node[@"interactable"] = interactable;
  if (focused)
    node[@"focused"] = focused;
  if (hasTextEntry)
    node[@"has_text_entry"] = hasTextEntry;

  CGRect frame;
  if (vp_ax_rect(element, "frame", &frame)) {
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CGRect pixelFrame = vp_scale_rect(frame, scaleX, scaleY);
    CGPoint pixelCenter = CGPointMake(center.x * scaleX, center.y * scaleY);
    node[@"frame"] = vp_rect_dict(frame);
    node[@"center"] = vp_point_dict(center);
    node[@"frame_pixels"] = vp_rect_dict(pixelFrame);
    node[@"center_pixels"] = vp_point_dict(pixelCenter);
  }

  CGRect visibleFrame;
  if (vp_ax_rect(element, "visibleFrame", &visibleFrame)) {
    node[@"visible_frame"] = vp_rect_dict(visibleFrame);
    node[@"visible_frame_pixels"] =
        vp_rect_dict(vp_scale_rect(visibleFrame, scaleX, scaleY));
  }

  return node;
}

// MARK: - Command handler

NSDictionary *vp_handle_accessibility_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  double startMs = vp_now_ms();

  if (!vp_ax_load()) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"accessibility_tree unavailable: AXRuntime/AccessibilityUtilities not loaded";
    return r;
  }

  NSMutableDictionary *target = vp_resolve_target(msg);
  NSString *targetError = target[@"error"];
  if (targetError.length > 0) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = targetError;
    if (target[@"candidates"])
      r[@"candidates"] = target[@"candidates"];
    return r;
  }

  pid_t pid = [target[@"pid"] intValue];
  id appElement = vp_ax_application_element(pid);
  if (!appElement) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"could not create AX application element for pid %d", pid];
    return r;
  }

  int fetchTimeoutMs = vp_int_from_msg(msg, @"fetch_timeout_ms", 8000);
  if (fetchTimeoutMs < 0)
    fetchTimeoutMs = 0;
  if (fetchTimeoutMs > 60000)
    fetchTimeoutMs = 60000;

  int depth = vp_int_from_msg(msg, @"depth", -1);
  int maxNodes = vp_int_from_msg(msg, @"max_nodes", 500);
  if (maxNodes <= 0)
    maxNodes = 500;
  if (maxNodes > 5000)
    maxNodes = 5000;

  BOOL fetchTimedOut = NO;
  NSString *fetchSource = @"AXElementFetcher";
  NSArray *elements =
      vp_ax_fetch_elements_with_timeout(appElement, fetchTimeoutMs, &fetchTimedOut);
  if (!elements) {
    NSString *manualSource = nil;
    elements = vp_ax_fetch_elements_manual(appElement, (NSUInteger)maxNodes,
                                           fetchTimeoutMs, &manualSource);
    if (elements.count > 0) {
      fetchSource = manualSource ?: @"manual";
    } else {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] =
          fetchTimedOut
              ? [NSString stringWithFormat:@"AXElementFetcher timed out after %dms",
                                           fetchTimeoutMs]
              : @"AXElementFetcher failed";
      return r;
    }
  }

  int screenWidth = vp_int_from_msg(msg, @"screen_width", 0);
  int screenHeight = vp_int_from_msg(msg, @"screen_height", 0);
  double explicitScale = vp_double_from_msg(msg, @"scale", 0.0);

  CGRect appFrame = CGRectZero;
  BOOL hasAppFrame = vp_ax_rect(appElement, "frame", &appFrame);
  double scaleX = explicitScale > 0 ? explicitScale : 3.0;
  double scaleY = explicitScale > 0 ? explicitScale : 3.0;
  if (hasAppFrame && appFrame.size.width > 0 && screenWidth > 0)
    scaleX = (double)screenWidth / appFrame.size.width;
  if (hasAppFrame && appFrame.size.height > 0 && screenHeight > 0)
    scaleY = (double)screenHeight / appFrame.size.height;

  NSMutableArray *flatNodes = [NSMutableArray array];
  NSMutableArray *childNodes = [NSMutableArray array];

  NSInteger nextID = 1;
  for (id element in elements) {
    if (flatNodes.count >= (NSUInteger)maxNodes)
      break;
    NSMutableDictionary *node = vp_ax_node(element, nextID, nil, scaleX, scaleY);
    node[@"index"] = @(nextID - 1);
    [flatNodes addObject:node];
    [childNodes addObject:node];
    nextID++;
  }

  NSMutableDictionary *root = vp_ax_node(appElement, 0, @"application", scaleX, scaleY);
  root[@"bundle_id"] = target[@"bundle_id"] ?: root[@"bundle_id"] ?: @"";
  root[@"pid"] = @(pid);
  root[@"target_source"] = target[@"source"] ?: @"";
  if (depth != 0)
    root[@"children"] = childNodes;

  double pointWidth = hasAppFrame ? appFrame.size.width : 0.0;
  double pointHeight = hasAppFrame ? appFrame.size.height : 0.0;
  if (screenWidth <= 0 && pointWidth > 0)
    screenWidth = (int)llround(pointWidth * scaleX);
  if (screenHeight <= 0 && pointHeight > 0)
    screenHeight = (int)llround(pointHeight * scaleY);

  NSMutableDictionary *r = vp_make_response(@"accessibility_tree", reqId);
  r[@"ok"] = @YES;
  r[@"pid"] = @(pid);
  r[@"bundle_id"] = target[@"bundle_id"] ?: @"";
  r[@"name"] = target[@"name"] ?: @"";
  r[@"target_source"] = target[@"source"] ?: @"";
  r[@"node_count"] = @(flatNodes.count);
  r[@"truncated"] = @(elements.count > flatNodes.count);
  r[@"depth"] = @(depth);
  r[@"max_nodes"] = @(maxNodes);
  r[@"fetch_source"] = fetchSource;
  r[@"fetch_timed_out"] = @(fetchTimedOut);
  r[@"scale"] = @{@"x" : @(scaleX), @"y" : @(scaleY)};
  r[@"screen"] = @{
    @"points" : @{@"width" : @(pointWidth), @"height" : @(pointHeight)},
    @"pixels" : @{@"width" : @(screenWidth), @"height" : @(screenHeight)},
  };
  r[@"tree"] = root;
  r[@"nodes"] = flatNodes;
  r[@"query_ms"] = @((int)llround(vp_now_ms() - startMs));
  return r;
}
