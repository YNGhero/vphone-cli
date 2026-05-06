#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

static NSDictionary *VPProfile;
static NSString *VPBundleID;
static NSString *VPProfilePath;
static BOOL VPEnabled;
static BOOL VPAuditReads;
static BOOL VPAuditMobileGestalt;
static BOOL VPSpoofMobileGestalt;
static BOOL VPSpoofProductType;
static NSMutableSet<NSString *> *VPLoggedReads;

static void VPLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;
    NSString *line = [NSString stringWithFormat:@"%@ [VPhoneProfile] %@\n", NSDate.date.description, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    int fd = open("/tmp/vphone_profile_tweak.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    (void)write(fd, data.bytes, data.length);
    close(fd);
}

static NSString *VPString(NSString *key) {
    id value = VPProfile[key];
    if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) {
        return value;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *s = [value stringValue];
        return s.length ? s : nil;
    }
    return nil;
}

static BOOL VPBool(NSString *key, BOOL defaultValue) {
    id value = VPProfile[key];
    if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    return defaultValue;
}

static void VPLogReadOnce(NSString *name) {
    if (!name.length) return;
    @synchronized ([NSProcessInfo processInfo]) {
        if (!VPLoggedReads) VPLoggedReads = [NSMutableSet set];
        if ([VPLoggedReads containsObject:name]) return;
        [VPLoggedReads addObject:name];
    }
    VPLog(@"read %@", name);
}

static NSArray<NSString *> *VPStringArray(NSString *key) {
    id value = VPProfile[key];
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            if ([item isKindOfClass:NSString.class] && [item length] > 0) [out addObject:item];
        }
        return out.count ? out : nil;
    }
    NSString *single = VPString(key);
    return single.length ? @[single] : nil;
}

static NSUUID *VPUUID(NSString *key) {
    NSString *value = VPString(key);
    if (!value.length) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    if (uuid) return uuid;
    return nil;
}

static BOOL VPLoadProfile(void) {
    VPBundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (!VPBundleID.length) return NO;

    NSString *name = [VPBundleID stringByAppendingPathExtension:@"json"];
    NSArray<NSString *> *roots = @[
        @"/var/mobile/vphone_app_profiles",
        @"/private/var/mobile/vphone_app_profiles"
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        NSString *path = [root stringByAppendingPathComponent:name];
        if (![fm isReadableFileAtPath:path]) continue;
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *profile = (NSDictionary *)obj;
        NSString *profileBundle = [profile[@"bundle_id"] isKindOfClass:NSString.class] ? profile[@"bundle_id"] : @"";
        if (profileBundle.length && ![profileBundle isEqualToString:VPBundleID]) continue;
        VPProfile = profile;
        VPProfilePath = path;
        VPEnabled = VPBool(@"enabled", YES);
        return VPEnabled;
    }
    return NO;
}

static id (*orig_UIDevice_name)(id, SEL);
static id (*orig_UIDevice_model)(id, SEL);
static id (*orig_UIDevice_localizedModel)(id, SEL);
static id (*orig_UIDevice_systemName)(id, SEL);
static id (*orig_UIDevice_systemVersion)(id, SEL);
static id (*orig_UIDevice_identifierForVendor)(id, SEL);

static id rep_UIDevice_name(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"UIDevice.name -> deviceName");
    NSString *v = VPString(@"deviceName");
    return v ?: (orig_UIDevice_name ? orig_UIDevice_name(self, _cmd) : nil);
}

static id rep_UIDevice_model(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"UIDevice.model -> model");
    NSString *v = VPString(@"model");
    return v ?: (orig_UIDevice_model ? orig_UIDevice_model(self, _cmd) : nil);
}

static id rep_UIDevice_localizedModel(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"UIDevice.localizedModel -> localizedModel");
    NSString *v = VPString(@"localizedModel") ?: VPString(@"model");
    return v ?: (orig_UIDevice_localizedModel ? orig_UIDevice_localizedModel(self, _cmd) : nil);
}

static id rep_UIDevice_systemName(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"UIDevice.systemName -> systemName");
    NSString *v = VPString(@"systemName");
    return v ?: (orig_UIDevice_systemName ? orig_UIDevice_systemName(self, _cmd) : nil);
}

static id rep_UIDevice_systemVersion(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"UIDevice.systemVersion -> systemVersion");
    NSString *v = VPString(@"systemVersion");
    return v ?: (orig_UIDevice_systemVersion ? orig_UIDevice_systemVersion(self, _cmd) : nil);
}

static id rep_UIDevice_identifierForVendor(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"UIDevice.identifierForVendor -> idfv");
    NSUUID *uuid = VPUUID(@"idfv");
    return uuid ?: (orig_UIDevice_identifierForVendor ? orig_UIDevice_identifierForVendor(self, _cmd) : nil);
}

static id (*orig_AS_advertisingIdentifier)(id, SEL);
static BOOL (*orig_AS_isAdvertisingTrackingEnabled)(id, SEL);

static id rep_AS_advertisingIdentifier(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"ASIdentifierManager.advertisingIdentifier -> idfa");
    NSUUID *uuid = VPUUID(@"idfa");
    return uuid ?: (orig_AS_advertisingIdentifier ? orig_AS_advertisingIdentifier(self, _cmd) : nil);
}

static BOOL rep_AS_isAdvertisingTrackingEnabled(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"ASIdentifierManager.isAdvertisingTrackingEnabled -> advertisingTrackingEnabled");
    return VPBool(@"advertisingTrackingEnabled", YES);
}

static NSInteger (*orig_ATT_trackingAuthorizationStatus)(id, SEL);
static NSInteger rep_ATT_trackingAuthorizationStatus(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"ATTrackingManager.trackingAuthorizationStatus -> trackingAuthorized");
    id value = VPProfile[@"trackingAuthorizationStatus"];
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    if (VPBool(@"trackingAuthorized", YES)) return 3; // ATTrackingManagerAuthorizationStatusAuthorized
    return orig_ATT_trackingAuthorizationStatus ? orig_ATT_trackingAuthorizationStatus(self, _cmd) : 0;
}

static id (*orig_NSLocale_currentLocale)(id, SEL);
static id (*orig_NSLocale_autoupdatingCurrentLocale)(id, SEL);
static id (*orig_NSLocale_preferredLanguages)(id, SEL);

static NSLocale *VPLocale(void) {
    NSString *identifier = VPString(@"localeIdentifier") ?: VPString(@"locale");
    if (!identifier.length) return nil;
    return [NSLocale localeWithLocaleIdentifier:identifier];
}

static id rep_NSLocale_currentLocale(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"NSLocale.currentLocale -> localeIdentifier");
    return VPLocale() ?: (orig_NSLocale_currentLocale ? orig_NSLocale_currentLocale(self, _cmd) : nil);
}

static id rep_NSLocale_autoupdatingCurrentLocale(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"NSLocale.autoupdatingCurrentLocale -> localeIdentifier");
    return VPLocale() ?: (orig_NSLocale_autoupdatingCurrentLocale ? orig_NSLocale_autoupdatingCurrentLocale(self, _cmd) : nil);
}

static id rep_NSLocale_preferredLanguages(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"NSLocale.preferredLanguages -> preferredLanguages");
    NSArray *langs = VPStringArray(@"preferredLanguages");
    return langs ?: (orig_NSLocale_preferredLanguages ? orig_NSLocale_preferredLanguages(self, _cmd) : nil);
}

static id (*orig_NSTimeZone_localTimeZone)(id, SEL);
static id (*orig_NSTimeZone_systemTimeZone)(id, SEL);
static id (*orig_NSTimeZone_defaultTimeZone)(id, SEL);

static NSTimeZone *VPTimeZone(void) {
    NSString *name = VPString(@"timeZone") ?: VPString(@"timezone");
    if (!name.length) return nil;
    return [NSTimeZone timeZoneWithName:name];
}

static id rep_NSTimeZone_localTimeZone(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"NSTimeZone.localTimeZone -> timeZone");
    return VPTimeZone() ?: (orig_NSTimeZone_localTimeZone ? orig_NSTimeZone_localTimeZone(self, _cmd) : nil);
}

static id rep_NSTimeZone_systemTimeZone(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"NSTimeZone.systemTimeZone -> timeZone");
    return VPTimeZone() ?: (orig_NSTimeZone_systemTimeZone ? orig_NSTimeZone_systemTimeZone(self, _cmd) : nil);
}

static id rep_NSTimeZone_defaultTimeZone(id self, SEL _cmd) {
    if (VPAuditReads) VPLogReadOnce(@"NSTimeZone.defaultTimeZone -> timeZone");
    return VPTimeZone() ?: (orig_NSTimeZone_defaultTimeZone ? orig_NSTimeZone_defaultTimeZone(self, _cmd) : nil);
}

static id (*orig_NSUserDefaults_objectForKey)(id, SEL, id);
static id rep_NSUserDefaults_objectForKey(id self, SEL _cmd, id key) {
    if ([key isKindOfClass:NSString.class]) {
        NSString *k = (NSString *)key;
        if ([k isEqualToString:@"AppleLanguages"]) {
            if (VPAuditReads) VPLogReadOnce(@"NSUserDefaults.AppleLanguages -> preferredLanguages");
            NSArray *langs = VPStringArray(@"preferredLanguages");
            if (langs) return langs;
        }
        if ([k isEqualToString:@"AppleLocale"]) {
            if (VPAuditReads) VPLogReadOnce(@"NSUserDefaults.AppleLocale -> localeIdentifier");
            NSString *locale = VPString(@"localeIdentifier") ?: VPString(@"locale");
            if (locale.length) return locale;
        }
    }
    return orig_NSUserDefaults_objectForKey ? orig_NSUserDefaults_objectForKey(self, _cmd, key) : nil;
}

static CFTypeRef (*orig_MGCopyAnswer)(CFStringRef key);
static CFTypeRef (*orig_MGCopyAnswerWithError)(CFStringRef key, CFDictionaryRef options, CFErrorRef *error);
static int (*orig_uname)(struct utsname *);
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);

typedef void (*MSHookFunctionType)(void *symbol, void *replace, void **result);

static NSString *VPProductType(void) {
    return VPString(@"productType") ?: VPString(@"hardwareMachine");
}

static BOOL VPIsProductGestaltKey(NSString *key) {
    if (!key.length) return NO;
    return [key isEqualToString:@"ProductType"] ||
           [key isEqualToString:@"MarketingProductName"] ||
           [key isEqualToString:@"HWModelStr"];
}

static CFTypeRef VPCopyGestaltValue(CFStringRef cfKey, BOOL productOnly) {
    if (!cfKey) return NULL;
    NSString *key = (__bridge NSString *)cfKey;
    NSString *value = nil;

    if (productOnly && !VPIsProductGestaltKey(key)) return NULL;

    if ([key isEqualToString:@"DeviceName"] ||
        [key isEqualToString:@"UserAssignedDeviceName"] ||
        [key isEqualToString:@"ComputerName"]) {
        value = VPString(@"deviceName");
    } else if ([key isEqualToString:@"SerialNumber"]) {
        value = VPString(@"serial");
    } else if ([key isEqualToString:@"UniqueDeviceID"] ||
               [key isEqualToString:@"UniqueDeviceIDString"] ||
               [key isEqualToString:@"UDID"] ||
               [key isEqualToString:@"OpaqueDeviceID"]) {
        value = VPString(@"udid") ?: VPString(@"oudid");
    } else if ([key isEqualToString:@"WifiAddress"] ||
               [key isEqualToString:@"WiFiAddress"]) {
        value = VPString(@"wifiAddress");
    } else if ([key isEqualToString:@"BluetoothAddress"]) {
        value = VPString(@"bluetoothAddress");
    } else if ([key isEqualToString:@"ProductType"]) {
        value = VPProductType();
    } else if ([key isEqualToString:@"HWModelStr"]) {
        value = VPString(@"hardwareModel");
        if (!productOnly && !value.length) value = VPProductType();
    } else if ([key isEqualToString:@"ProductVersion"]) {
        value = VPString(@"systemVersion");
    } else if ([key isEqualToString:@"BuildVersion"]) {
        value = VPString(@"buildVersion");
    } else if ([key isEqualToString:@"MarketingProductName"]) {
        value = VPString(@"marketingProductName");
    } else if ([key isEqualToString:@"RegionCode"]) {
        value = VPString(@"regionCode");
    } else if ([key isEqualToString:@"RegionInfo"]) {
        value = VPString(@"regionInfo");
    }

    if (!value.length) return NULL;
    return CFRetain((__bridge CFTypeRef)value);
}

static CFTypeRef rep_MGCopyAnswer(CFStringRef key) {
    NSString *keyString = key ? (__bridge NSString *)key : @"<null>";
    if (VPAuditMobileGestalt) {
        VPLogReadOnce([NSString stringWithFormat:@"MGCopyAnswer:%@", keyString]);
    }
    if (VPSpoofMobileGestalt || VPSpoofProductType) {
        CFTypeRef value = VPCopyGestaltValue(key, !VPSpoofMobileGestalt);
        if (value) return value;
    }
    return orig_MGCopyAnswer ? orig_MGCopyAnswer(key) : NULL;
}

static CFTypeRef rep_MGCopyAnswerWithError(CFStringRef key, CFDictionaryRef options, CFErrorRef *error) {
    CFTypeRef value = VPCopyGestaltValue(key, NO);
    if (value) return value;
    return orig_MGCopyAnswerWithError ? orig_MGCopyAnswerWithError(key, options, error) : NULL;
}

static int VPReturnSysctlString(NSString *value, void *oldp, size_t *oldlenp) {
    if (!value.length) return -2;
    const char *bytes = value.UTF8String;
    if (!bytes) return -2;
    size_t needed = strlen(bytes) + 1;
    if (!oldlenp) {
        errno = EFAULT;
        return -1;
    }
    if (!oldp) {
        *oldlenp = needed;
        return 0;
    }
    size_t available = *oldlenp;
    *oldlenp = needed;
    if (available < needed) {
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, bytes, needed);
    return 0;
}

static int rep_uname(struct utsname *name) {
    int result = orig_uname ? orig_uname(name) : 0;
    NSString *productType = VPProductType();
    if (result == 0 && name && productType.length) {
        snprintf(name->machine, sizeof(name->machine), "%s", productType.UTF8String);
    }
    return result;
}

static int rep_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (VPSpoofProductType && name && !newp && newlen == 0) {
        if (strcmp(name, "hw.machine") == 0) {
            int handled = VPReturnSysctlString(VPProductType(), oldp, oldlenp);
            if (handled != -2) return handled;
        } else if (strcmp(name, "hw.model") == 0) {
            int handled = VPReturnSysctlString(VPString(@"hardwareModel"), oldp, oldlenp);
            if (handled != -2) return handled;
        }
    }
    return orig_sysctlbyname ? orig_sysctlbyname(name, oldp, oldlenp, newp, newlen) : -1;
}

static int rep_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (VPSpoofProductType && name && namelen >= 2 && !newp && newlen == 0 && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE) {
            int handled = VPReturnSysctlString(VPProductType(), oldp, oldlenp);
            if (handled != -2) return handled;
        }
#ifdef HW_MODEL
        if (name[1] == HW_MODEL) {
            int handled = VPReturnSysctlString(VPString(@"hardwareModel"), oldp, oldlenp);
            if (handled != -2) return handled;
        }
#endif
    }
    return orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;
}

static void VPHookInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *orig) {
    if (!cls || !sel || !replacement || !orig) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    *orig = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void VPHookClassMethod(Class cls, SEL sel, IMP replacement, IMP *orig) {
    if (!cls) return;
    VPHookInstanceMethod(object_getClass(cls), sel, replacement, orig);
}

static void VPHookObjectiveC(void) {
    Class UIDevice = NSClassFromString(@"UIDevice");
    VPHookInstanceMethod(UIDevice, @selector(name), (IMP)rep_UIDevice_name, (IMP *)&orig_UIDevice_name);
    VPHookInstanceMethod(UIDevice, @selector(model), (IMP)rep_UIDevice_model, (IMP *)&orig_UIDevice_model);
    VPHookInstanceMethod(UIDevice, @selector(localizedModel), (IMP)rep_UIDevice_localizedModel, (IMP *)&orig_UIDevice_localizedModel);
    VPHookInstanceMethod(UIDevice, @selector(systemName), (IMP)rep_UIDevice_systemName, (IMP *)&orig_UIDevice_systemName);
    VPHookInstanceMethod(UIDevice, @selector(systemVersion), (IMP)rep_UIDevice_systemVersion, (IMP *)&orig_UIDevice_systemVersion);
    VPHookInstanceMethod(UIDevice, @selector(identifierForVendor), (IMP)rep_UIDevice_identifierForVendor, (IMP *)&orig_UIDevice_identifierForVendor);

    dlopen("/System/Library/Frameworks/AdSupport.framework/AdSupport", RTLD_NOW | RTLD_GLOBAL);
    Class ASIdentifierManager = NSClassFromString(@"ASIdentifierManager");
    VPHookInstanceMethod(ASIdentifierManager, @selector(advertisingIdentifier), (IMP)rep_AS_advertisingIdentifier, (IMP *)&orig_AS_advertisingIdentifier);
    VPHookInstanceMethod(ASIdentifierManager, @selector(isAdvertisingTrackingEnabled), (IMP)rep_AS_isAdvertisingTrackingEnabled, (IMP *)&orig_AS_isAdvertisingTrackingEnabled);

    dlopen("/System/Library/Frameworks/AppTrackingTransparency.framework/AppTrackingTransparency", RTLD_NOW | RTLD_GLOBAL);
    Class ATTrackingManager = NSClassFromString(@"ATTrackingManager");
    VPHookClassMethod(ATTrackingManager, @selector(trackingAuthorizationStatus), (IMP)rep_ATT_trackingAuthorizationStatus, (IMP *)&orig_ATT_trackingAuthorizationStatus);

    Class NSLocaleClass = NSLocale.class;
    VPHookClassMethod(NSLocaleClass, @selector(currentLocale), (IMP)rep_NSLocale_currentLocale, (IMP *)&orig_NSLocale_currentLocale);
    VPHookClassMethod(NSLocaleClass, @selector(autoupdatingCurrentLocale), (IMP)rep_NSLocale_autoupdatingCurrentLocale, (IMP *)&orig_NSLocale_autoupdatingCurrentLocale);
    VPHookClassMethod(NSLocaleClass, @selector(preferredLanguages), (IMP)rep_NSLocale_preferredLanguages, (IMP *)&orig_NSLocale_preferredLanguages);

    Class NSTimeZoneClass = NSTimeZone.class;
    VPHookClassMethod(NSTimeZoneClass, @selector(localTimeZone), (IMP)rep_NSTimeZone_localTimeZone, (IMP *)&orig_NSTimeZone_localTimeZone);
    VPHookClassMethod(NSTimeZoneClass, @selector(systemTimeZone), (IMP)rep_NSTimeZone_systemTimeZone, (IMP *)&orig_NSTimeZone_systemTimeZone);
    VPHookClassMethod(NSTimeZoneClass, @selector(defaultTimeZone), (IMP)rep_NSTimeZone_defaultTimeZone, (IMP *)&orig_NSTimeZone_defaultTimeZone);

    VPHookInstanceMethod(NSUserDefaults.class, @selector(objectForKey:), (IMP)rep_NSUserDefaults_objectForKey, (IMP *)&orig_NSUserDefaults_objectForKey);
}

static MSHookFunctionType VPGetMSHookFunction(void) {
    static MSHookFunctionType hook;
    static BOOL tried;
    if (tried) return hook;
    tried = YES;
    hook = (MSHookFunctionType)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!hook) {
        const char *envPath = getenv("JB_TWEAKLOADER_PATH");
        const char *paths[] = {
            "/cores/libellekit.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            "/usr/lib/libellekit.dylib",
            "/var/jb/usr/lib/libsubstrate.dylib",
            "/usr/lib/libsubstrate.dylib",
            NULL
        };
        if (envPath && envPath[0]) {
            void *handle = dlopen(envPath, RTLD_NOW | RTLD_GLOBAL);
            if (handle) hook = (MSHookFunctionType)dlsym(handle, "MSHookFunction");
        }
        for (size_t i = 0; paths[i]; i++) {
            if (hook) break;
            if (!paths[i][0]) continue;
            void *handle = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
            if (!handle) continue;
            hook = (MSHookFunctionType)dlsym(handle, "MSHookFunction");
            if (hook) break;
        }
    }
    if (!hook) VPLog(@"MSHookFunction unavailable; C function hooks disabled");
    return hook;
}

static void VPHookSymbol(const char *libraryPath, const char *symbolName, void *replacement, void **original) {
    MSHookFunctionType hook = VPGetMSHookFunction();
    if (!hook || !symbolName || !replacement || !original) return;
    void *handle = libraryPath ? dlopen(libraryPath, RTLD_NOW | RTLD_GLOBAL) : RTLD_DEFAULT;
    void *sym = handle ? dlsym(handle, symbolName) : NULL;
    if (!sym) sym = dlsym(RTLD_DEFAULT, symbolName);
    if (sym) {
        hook(sym, replacement, original);
    } else {
        VPLog(@"symbol not found: %s", symbolName);
    }
}

static void VPHookHardwareIdentity(void) {
    VPHookSymbol("/usr/lib/libSystem.B.dylib", "uname", (void *)rep_uname, (void **)&orig_uname);
    VPHookSymbol("/usr/lib/libSystem.B.dylib", "sysctlbyname", (void *)rep_sysctlbyname, (void **)&orig_sysctlbyname);
    VPHookSymbol("/usr/lib/libSystem.B.dylib", "sysctl", (void *)rep_sysctl, (void **)&orig_sysctl);
}

static void VPHookMobileGestalt(void) {
    MSHookFunctionType hook = VPGetMSHookFunction();
    if (!hook) return;

    void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW | RTLD_GLOBAL);
    void *sym = mg ? dlsym(mg, "MGCopyAnswer") : dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (sym) hook(sym, (void *)rep_MGCopyAnswer, (void **)&orig_MGCopyAnswer);

    // Keep MGCopyAnswerWithError disabled for now. Its private signature has
    // changed across iOS releases, and an arity mismatch can stall app launch.
    // MGCopyAnswer covers the common app-side MobileGestalt reads we need.
}

__attribute__((constructor))
static void VPhoneProfileTweakInit(void) {
    @autoreleasepool {
        if (!VPLoadProfile()) return;
        VPAuditReads = VPBool(@"auditReads", NO);
        VPAuditMobileGestalt = VPBool(@"auditMobileGestalt", NO);
        VPSpoofMobileGestalt = VPBool(@"hookMobileGestalt", NO);
        VPSpoofProductType = VPBool(@"spoofProductType", YES) && VPProductType().length > 0;
        VPHookObjectiveC();
        if (VPSpoofProductType) {
            VPHookHardwareIdentity();
        }
        if (VPSpoofMobileGestalt || VPAuditMobileGestalt || VPSpoofProductType) {
            VPHookMobileGestalt();
        }
        VPLog(@"enabled bundle=%@ profile=%@ auditReads=%d auditMobileGestalt=%d hookMobileGestalt=%d spoofProductType=%d productType=%@", VPBundleID, VPProfilePath, VPAuditReads, VPAuditMobileGestalt, VPSpoofMobileGestalt, VPSpoofProductType, VPProductType());
    }
}
