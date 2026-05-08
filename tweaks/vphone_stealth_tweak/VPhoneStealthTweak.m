#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <dirent.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/statvfs.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <mach-o/dyld.h>

#ifdef __has_include
#  if __has_include(<sys/proc.h>)
#    include <sys/proc.h>
#  endif
#  if __has_include(<sys/codesign.h>)
#    include <sys/codesign.h>
#  endif
#endif

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif
#ifndef ENOTSUP
#define ENOTSUP 45
#endif

typedef int (*MSHookFunctionType)(void *symbol, void *replace, void **result);

static BOOL VSAudit;
static NSMutableSet<NSString *> *VSLogged;

static int VSAsciiLower(int c) {
    return (c >= 'A' && c <= 'Z') ? (c + ('a' - 'A')) : c;
}

static BOOL VSCStringHasPrefixCI(const char *s, const char *prefix) {
    if (!s || !prefix) return NO;
    while (*prefix) {
        if (!*s || VSAsciiLower((unsigned char)*s) != VSAsciiLower((unsigned char)*prefix)) return NO;
        s++;
        prefix++;
    }
    return YES;
}

static BOOL VSCStringEqualsCI(const char *a, const char *b) {
    if (!a || !b) return NO;
    while (*a || *b) {
        if (VSAsciiLower((unsigned char)*a) != VSAsciiLower((unsigned char)*b)) return NO;
        a++;
        b++;
    }
    return YES;
}

static BOOL VSCStringContainsCI(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) return NO;
    for (const char *p = haystack; *p; p++) {
        if (VSCStringHasPrefixCI(p, needle)) return YES;
    }
    return NO;
}

static BOOL VSPathEqualsOrHasChildPrefixCI(const char *path, const char *prefix) {
    if (!path || !prefix || !*prefix) return NO;
    size_t n = strlen(prefix);
    if (!VSCStringHasPrefixCI(path, prefix)) return NO;
    return path[n] == '\0' || path[n] == '/';
}

static BOOL VSPathMatchesPrefixNormalizedCI(const char *path, const char *prefix) {
    if (VSPathEqualsOrHasChildPrefixCI(path, prefix)) return YES;
    if (VSCStringHasPrefixCI(path, "/private/var/") && VSCStringHasPrefixCI(prefix, "/var/")) {
        char normalized[1024];
        snprintf(normalized, sizeof(normalized), "/var/%s", path + strlen("/private/var/"));
        return VSPathEqualsOrHasChildPrefixCI(normalized, prefix);
    }
    if (VSCStringHasPrefixCI(path, "/var/") && VSCStringHasPrefixCI(prefix, "/private/var/")) {
        char normalized[1024];
        snprintf(normalized, sizeof(normalized), "/private/var/%s", path + strlen("/var/"));
        return VSPathEqualsOrHasChildPrefixCI(normalized, prefix);
    }
    return NO;
}

static BOOL VSIsInternalLogPathC(const char *path) {
    return path && (
        VSCStringEqualsCI(path, "/tmp/vphone_stealth_tweak.log") ||
        VSCStringContainsCI(path, "/var/mobile/Library/TweakLoader/tweakloader.log") ||
        VSCStringContainsCI(path, "/var/jb/var/mobile/Library/TweakLoader/tweakloader.log")
    );
}

static BOOL VSIsSuspiciousPathC(const char *path) {
    if (!path || !*path || VSIsInternalLogPathC(path)) return NO;
    static const char *prefixes[] = {
        "/var/jb", "/cores",
        "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app", "/Applications/Filza.app",
        "/Applications/TrollStore.app", "/Applications/TrollStoreLite.app",
        "/Library/MobileSubstrate", "/Library/PreferenceLoader", "/Library/PreferenceBundles",
        "/etc/apt", "/var/lib/apt", "/var/cache/apt", "/var/log/apt",
        "/usr/sbin/sshd", "/usr/bin/ssh", "/usr/libexec/ssh-keysign",
        "/bin/bash", "/usr/bin/bash",
        NULL
    };
    for (const char **p = prefixes; *p; p++) {
        if (VSPathMatchesPrefixNormalizedCI(path, *p)) return YES;
    }
    static const char *tokens[] = {
        "mobilesubstrate", "substrateloader", "substitute", "libhooker", "frida", "fridagadget",
        "cydia", "sileo", "trollstore", "palera1n", "checkra1n", "ellekit",
        "tweakloader", "vphonestealthtweak", "vphoneprofiletweak", "instagramaudittweak",
        NULL
    };
    for (const char **t = tokens; *t; t++) {
        if (VSCStringContainsCI(path, *t)) return YES;
    }
    return NO;
}

static BOOL VSIsSuspiciousDlopenPathC(const char *path) {
    if (!path || !*path) return NO;
    static const char *tokens[] = {
        "mobilesubstrate", "substrate", "substitute", "libhooker", "ellekit",
        "frida", "fridagadget", "tweakinject", "tweakloader",
        "vphonestealthtweak", "vphoneprofiletweak", "instagramaudittweak",
        NULL
    };
    for (const char **t = tokens; *t; t++) {
        if (VSCStringContainsCI(path, *t)) return YES;
    }
    return VSIsSuspiciousPathC(path);
}

static BOOL VSIsHiddenEnvNameC(const char *name) {
    if (!name || !*name) return NO;
    return VSCStringHasPrefixCI(name, "DYLD_") ||
           VSCStringHasPrefixCI(name, "JB_") ||
           VSCStringContainsCI(name, "substrate") ||
           VSCStringContainsCI(name, "frida");
}

static void VSLogC(const char *tag, const char *value) {
    if (!tag) return;
    char line[1024];
    int n = snprintf(line, sizeof(line), "[VPhoneStealth] %s%s%s\n", tag, value ? " " : "", value ? value : "");
    if (n <= 0) return;
    if (n > (int)sizeof(line)) n = (int)sizeof(line);
    int fd = open("/tmp/vphone_stealth_tweak.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    (void)write(fd, line, (size_t)n);
    close(fd);
}

static void VSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;
    NSString *line = [NSString stringWithFormat:@"%@ [VPhoneStealth] %@\n", NSDate.date.description, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    int fd = open("/tmp/vphone_stealth_tweak.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    (void)write(fd, data.bytes, data.length);
    close(fd);
}

static void VSLogOnce(NSString *message) {
    if (!message.length) return;
    @synchronized (NSProcessInfo.processInfo) {
        if (!VSLogged) VSLogged = [NSMutableSet set];
        if ([VSLogged containsObject:message]) return;
        [VSLogged addObject:message];
    }
    VSLog(@"%@", message);
}

static NSString *VSStringFromPath(const char *path) {
    if (!path || !path[0]) return nil;
    return [NSString stringWithUTF8String:path] ?: [NSString stringWithCString:path encoding:NSISOLatin1StringEncoding];
}

static NSString *VSNormalizePathString(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length) return @"";
    NSString *out = path.stringByStandardizingPath;
    if ([out hasPrefix:@"/private/var/"]) out = [out stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/" options:0 range:NSMakeRange(0, @"/private/var/".length)];
    if ([out hasPrefix:@"/var/containers/Bundle/Application/"] || [out containsString:@"/Instagram.app/"]) return out;
    return out;
}

static BOOL VSContainsToken(NSString *s, NSArray<NSString *> *tokens) {
    if (!s.length) return NO;
    NSString *lower = s.lowercaseString;
    for (NSString *token in tokens) {
        if ([lower containsString:token.lowercaseString]) return YES;
    }
    return NO;
}

static BOOL VSIsAllowedOwnTweakPath(NSString *p) {
    NSString *lower = p.lowercaseString;
    return [lower containsString:@"/vphonestealthtweak.dylib"] ||
           [lower containsString:@"/vphoneprofiletweak.dylib"] ||
           [lower containsString:@"/instagramaudittweak.dylib"] ||
           [lower containsString:@"/tweakloader.dylib"];
}

static BOOL VSIsSuspiciousPathString(NSString *rawPath) {
    NSString *p = VSNormalizePathString(rawPath);
    if (!p.length || VSIsAllowedOwnTweakPath(p)) return NO;
    NSString *lower = p.lowercaseString;

    NSArray<NSString *> *prefixes = @[
        @"/var/jb", @"/private/var/jb", @"/cores",
        @"/applications/cydia.app", @"/applications/sileo.app", @"/applications/zebra.app", @"/applications/filza.app",
        @"/applications/trollstore.app", @"/applications/trollstorelite.app",
        @"/library/mobilesubstrate", @"/library/preferenceloader", @"/library/preferencebundles",
        @"/etc/apt", @"/var/lib/apt", @"/private/var/lib/apt", @"/var/cache/apt", @"/var/log/apt",
        @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/usr/libexec/ssh-keysign",
        @"/bin/bash", @"/usr/bin/bash",
    ];
    for (NSString *prefix in prefixes) {
        if ([lower isEqualToString:prefix] || [lower hasPrefix:[prefix stringByAppendingString:@"/"]]) return YES;
    }

    NSArray<NSString *> *tokens = @[
        @"mobilesubstrate", @"substrateloader", @"substitute", @"libhooker", @"frida", @"fridagadget",
        @"cydia", @"sileo", @"trollstore", @"palera1n", @"checkra1n", @"ellekit"
    ];
    return VSContainsToken(lower, tokens);
}

static BOOL VSIsSuspiciousCString(const char *path) {
    return VSIsSuspiciousPathString(VSStringFromPath(path));
}

static void VSBlockPathIfAuditing(const char *func, NSString *path) {
    if (!VSAudit && !VSIsSuspiciousPathString(path)) return;
    if (VSIsSuspiciousPathString(path)) VSLogOnce([NSString stringWithFormat:@"blocked %s %@", func, path ?: @"<null>"]);
}

static int (*orig_access)(const char *, int);
static int rep_access(const char *path, int mode) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked access", path); errno = ENOENT; return -1; }
    return orig_access ? orig_access(path, mode) : -1;
}

static int (*orig_stat)(const char *, struct stat *);
static int rep_stat(const char *path, struct stat *buf) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked stat", path); errno = ENOENT; return -1; }
    return orig_stat ? orig_stat(path, buf) : -1;
}

static int (*orig_lstat)(const char *, struct stat *);
static int rep_lstat(const char *path, struct stat *buf) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked lstat", path); errno = ENOENT; return -1; }
    return orig_lstat ? orig_lstat(path, buf) : -1;
}

static int (*orig_statfs)(const char *, struct statfs *);
static int rep_statfs(const char *path, struct statfs *buf) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked statfs", path); errno = ENOENT; return -1; }
    return orig_statfs ? orig_statfs(path, buf) : -1;
}

static int (*orig_open)(const char *, int, ...);
static int rep_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked open", path); errno = ENOENT; return -1; }
    if (!orig_open) return -1;
    if (flags & O_CREAT) return orig_open(path, flags, mode);
    return orig_open(path, flags);
}

static FILE *(*orig_fopen)(const char *, const char *);
static FILE *rep_fopen(const char *path, const char *mode) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked fopen", path); errno = ENOENT; return NULL; }
    return orig_fopen ? orig_fopen(path, mode) : NULL;
}

static DIR *(*orig_opendir)(const char *);
static DIR *rep_opendir(const char *path) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked opendir", path); errno = ENOENT; return NULL; }
    return orig_opendir ? orig_opendir(path) : NULL;
}

static char *(*orig_realpath)(const char *, char *);
static char *rep_realpath(const char *path, char *resolved) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked realpath", path); errno = ENOENT; return NULL; }
    char *ret = orig_realpath ? orig_realpath(path, resolved) : NULL;
    if (ret && VSIsSuspiciousPathC(ret)) { if (VSAudit) VSLogC("blocked realpath-result", ret); errno = ENOENT; return NULL; }
    return ret;
}

static ssize_t (*orig_readlink)(const char *, char *, size_t);
static ssize_t rep_readlink(const char *path, char *buf, size_t bufsiz) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked readlink", path); errno = ENOENT; return -1; }
    ssize_t ret = orig_readlink ? orig_readlink(path, buf, bufsiz) : -1;
    if (ret > 0 && buf) {
        char tmp[1024];
        size_t n = (size_t)ret < sizeof(tmp) - 1 ? (size_t)ret : sizeof(tmp) - 1;
        memcpy(tmp, buf, n);
        tmp[n] = '\0';
        if (!VSIsSuspiciousPathC(tmp)) return ret;
        if (VSAudit) VSLogC("blocked readlink-result", tmp);
        errno = ENOENT;
        return -1;
    }
    return ret;
}

static ssize_t (*orig_getxattr)(const char *, const char *, void *, size_t, u_int32_t, int);
static ssize_t rep_getxattr(const char *path, const char *name, void *value, size_t size, u_int32_t position, int options) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked getxattr", path); errno = ENOENT; return -1; }
    return orig_getxattr ? orig_getxattr(path, name, value, size, position, options) : -1;
}

static ssize_t (*orig_listxattr)(const char *, char *, size_t, int);
static ssize_t rep_listxattr(const char *path, char *namebuf, size_t size, int options) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked listxattr", path); errno = ENOENT; return -1; }
    return orig_listxattr ? orig_listxattr(path, namebuf, size, options) : -1;
}

static int (*orig_statvfs)(const char *, struct statvfs *);
static int rep_statvfs(const char *path, struct statvfs *buf) {
    if (VSIsSuspiciousPathC(path)) { if (VSAudit) VSLogC("blocked statvfs", path); errno = ENOENT; return -1; }
    return orig_statvfs ? orig_statvfs(path, buf) : -1;
}

static void *(*orig_dlopen)(const char *, int);
static void *rep_dlopen(const char *path, int mode) {
    if (VSIsSuspiciousDlopenPathC(path)) {
        if (VSAudit) VSLogC("blocked dlopen", path);
        errno = ENOENT;
        return NULL;
    }
    return orig_dlopen ? orig_dlopen(path, mode) : NULL;
}

static char *(*orig_getenv)(const char *);
static char *rep_getenv(const char *name) {
    if (VSIsHiddenEnvNameC(name)) {
        if (VSAudit) VSLogC("hidden getenv", name);
        return NULL;
    }
    return orig_getenv ? orig_getenv(name) : NULL;
}

static const char *(*orig_dyld_get_image_name)(uint32_t);
static const char *rep_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name ? orig_dyld_get_image_name(image_index) : NULL;
    if (VSIsSuspiciousDlopenPathC(name)) {
        if (VSAudit) VSLogC("hidden dyld image", name);
        return "/System/Library/Frameworks/Foundation.framework/Foundation";
    }
    return name;
}

static int (*orig_fork)(void);
static int rep_fork(void) {
    VSLogOnce(@"blocked fork probe");
    errno = ENOTSUP;
    return -1;
}

static int (*orig_ptrace)(int, pid_t, caddr_t, int);
static int rep_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (request == PT_DENY_ATTACH) {
        VSLogOnce(@"ignored ptrace(PT_DENY_ATTACH)");
        return 0;
    }
    return orig_ptrace ? orig_ptrace(request, pid, addr, data) : -1;
}

static int (*orig_csops)(pid_t, unsigned int, void *, size_t);
static int rep_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    int ret = orig_csops ? orig_csops(pid, ops, useraddr, usersize) : -1;
    if (ret == 0 && ops == CS_OPS_STATUS && useraddr && usersize >= sizeof(uint32_t)) {
        uint32_t *flags = (uint32_t *)useraddr;
        *flags &= ~((uint32_t)CS_DEBUGGED);
    }
    return ret;
}

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int rep_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctlbyname ? orig_sysctlbyname(name, oldp, oldlenp, newp, newlen) : -1;
    if (ret == 0 && name && oldp && oldlenp) {
        if (strcmp(name, "kern.proc.pid") == 0 || strcmp(name, "kern.proc") == 0) {
#ifdef P_TRACED
            if (*oldlenp >= sizeof(struct kinfo_proc)) {
                struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
                kp->kp_proc.p_flag &= ~P_TRACED;
            }
#endif
        }
    }
    return ret;
}

static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int rep_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl ? orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen) : -1;
#ifdef P_TRACED
    if (ret == 0 && name && namelen >= 3 && oldp && oldlenp && name[0] == CTL_KERN && name[1] == KERN_PROC) {
        if (*oldlenp >= sizeof(struct kinfo_proc)) {
            struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
            kp->kp_proc.p_flag &= ~P_TRACED;
        }
    }
#endif
    return ret;
}

static BOOL (*orig_METADeviceIsJailbroken)(void);
static BOOL rep_METADeviceIsJailbroken(void) {
    if (VSAudit) VSLogC("forced METADeviceIsJailbroken", "0");
    return NO;
}

static BOOL (*orig_METADeviceAppearsJailbroken)(void);
static BOOL rep_METADeviceAppearsJailbroken(void) {
    if (VSAudit) VSLogC("forced METADeviceAppearsJailbroken", "0");
    return NO;
}

static id (*orig_IGDeviceReportWithJailbreakInfo)(void);
static id rep_IGDeviceReportWithJailbreakInfo(void) {
    if (VSAudit) VSLogC("forced IGDeviceReportWithJailbreakInfo", "jail_broken=no");
    return @{@"jail_broken": @"no"};
}

static BOOL (*orig_NSFileManager_fileExistsAtPath)(id, SEL, id);
static BOOL rep_NSFileManager_fileExistsAtPath(id self, SEL _cmd, id path) {
    if ([path isKindOfClass:NSString.class] && VSIsSuspiciousPathC([(NSString *)path UTF8String])) {
        if (VSAudit) VSLogC("blocked NSFM exists", [(NSString *)path UTF8String]);
        return NO;
    }
    return orig_NSFileManager_fileExistsAtPath ? orig_NSFileManager_fileExistsAtPath(self, _cmd, path) : NO;
}

static BOOL (*orig_NSFileManager_fileExistsAtPath_isDirectory)(id, SEL, id, BOOL *);
static BOOL rep_NSFileManager_fileExistsAtPath_isDirectory(id self, SEL _cmd, id path, BOOL *isDirectory) {
    if ([path isKindOfClass:NSString.class] && VSIsSuspiciousPathC([(NSString *)path UTF8String])) {
        if (VSAudit) VSLogC("blocked NSFM existsDir", [(NSString *)path UTF8String]);
        if (isDirectory) *isDirectory = NO;
        return NO;
    }
    return orig_NSFileManager_fileExistsAtPath_isDirectory ? orig_NSFileManager_fileExistsAtPath_isDirectory(self, _cmd, path, isDirectory) : NO;
}

static BOOL (*orig_NSFileManager_isReadableFileAtPath)(id, SEL, id);
static BOOL rep_NSFileManager_isReadableFileAtPath(id self, SEL _cmd, id path) {
    if ([path isKindOfClass:NSString.class] && VSIsSuspiciousPathC([(NSString *)path UTF8String])) {
        if (VSAudit) VSLogC("blocked NSFM readable", [(NSString *)path UTF8String]);
        return NO;
    }
    return orig_NSFileManager_isReadableFileAtPath ? orig_NSFileManager_isReadableFileAtPath(self, _cmd, path) : NO;
}

static BOOL (*orig_NSFileManager_isExecutableFileAtPath)(id, SEL, id);
static BOOL rep_NSFileManager_isExecutableFileAtPath(id self, SEL _cmd, id path) {
    if ([path isKindOfClass:NSString.class] && VSIsSuspiciousPathC([(NSString *)path UTF8String])) {
        if (VSAudit) VSLogC("blocked NSFM executable", [(NSString *)path UTF8String]);
        return NO;
    }
    return orig_NSFileManager_isExecutableFileAtPath ? orig_NSFileManager_isExecutableFileAtPath(self, _cmd, path) : NO;
}

static BOOL (*orig_UIApplication_canOpenURL)(id, SEL, id);
static BOOL rep_UIApplication_canOpenURL(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:NSURL.class]) {
        NSString *scheme = [[(NSURL *)url scheme] lowercaseString];
        if ([(@[@"cydia", @"sileo", @"zbra", @"filza", @"activator", @"undecimus"]) containsObject:scheme]) {
            VSLogOnce([NSString stringWithFormat:@"blocked canOpenURL %@", scheme]);
            return NO;
        }
    }
    return orig_UIApplication_canOpenURL ? orig_UIApplication_canOpenURL(self, _cmd, url) : NO;
}

static NSDictionary *(*orig_NSProcessInfo_environment)(id, SEL);
static NSDictionary *rep_NSProcessInfo_environment(id self, SEL _cmd) {
    NSDictionary *env = orig_NSProcessInfo_environment ? orig_NSProcessInfo_environment(self, _cmd) : nil;
    if (![env isKindOfClass:NSDictionary.class]) return env;
    NSMutableDictionary *m = nil;
    for (id key in env) {
        if (![key isKindOfClass:NSString.class]) continue;
        NSString *lower = [(NSString *)key lowercaseString];
        if ([lower hasPrefix:@"dyld_"] || [lower hasPrefix:@"jb_"] || [lower containsString:@"substrate"] || [lower containsString:@"frida"]) {
            if (!m) m = [env mutableCopy];
            [m removeObjectForKey:key];
        }
    }
    return m ?: env;
}

static uintptr_t rep_zero_noargs(id self, SEL _cmd) {
    VSLogOnce([NSString stringWithFormat:@"forced selector %@ -> 0", NSStringFromSelector(_cmd)]);
    return 0;
}

static void VSHookInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *orig) {
    if (!cls || !sel || !replacement || !orig) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    *orig = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void VSHookClassMethod(Class cls, SEL sel, IMP replacement, IMP *orig) {
    if (!cls) return;
    VSHookInstanceMethod(object_getClass(cls), sel, replacement, orig);
}

static void VSHookAllZeroArgSelector(SEL sel) {
    if (!sel) return;
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;
    Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) return;
    classCount = objc_getClassList(classes, classCount);
    int patched = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        Method m = class_getInstanceMethod(cls, sel);
        if (m && method_getNumberOfArguments(m) == 2) {
            method_setImplementation(m, (IMP)rep_zero_noargs);
            patched++;
        }
        Class meta = object_getClass(cls);
        Method cm = class_getInstanceMethod(meta, sel);
        if (cm && method_getNumberOfArguments(cm) == 2) {
            method_setImplementation(cm, (IMP)rep_zero_noargs);
            patched++;
        }
    }
    free(classes);
    if (patched) VSLog(@"patched selector %@ count=%d", NSStringFromSelector(sel), patched);
}

static MSHookFunctionType VSGetMSHookFunction(void) {
    static MSHookFunctionType hook;
    static BOOL tried;
    if (tried) return hook;
    tried = YES;
    hook = (MSHookFunctionType)dlsym(RTLD_DEFAULT, "MSHookFunction");
    const char *paths[] = {
        "/cores/libellekit.dylib",
        "/var/jb/usr/lib/libellekit.dylib",
        "/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libsubstrate.dylib",
        "/usr/lib/libsubstrate.dylib",
        NULL
    };
    for (size_t i = 0; !hook && paths[i]; i++) {
        void *handle = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (handle) hook = (MSHookFunctionType)dlsym(handle, "MSHookFunction");
    }
    if (!hook) VSLogC("MSHookFunction unavailable; C hooks disabled", NULL);
    return hook;
}

static BOOL VSHookSymbol(const char *libraryPath, const char *symbolName, void *replacement, void **original) {
    MSHookFunctionType hook = VSGetMSHookFunction();
    if (!hook || !symbolName || !replacement || !original) return NO;
    void *handle = libraryPath ? dlopen(libraryPath, RTLD_NOW | RTLD_GLOBAL) : RTLD_DEFAULT;
    void *sym = handle ? dlsym(handle, symbolName) : NULL;
    if (!sym) sym = dlsym(RTLD_DEFAULT, symbolName);
    if (sym) {
        hook(sym, replacement, original);
        return YES;
    }
    else if (VSAudit) VSLogC("symbol not found", symbolName);
    return NO;
}

static void VSHookCFunctions(void) {
    const char *libSystem = "/usr/lib/libSystem.B.dylib";
    VSHookSymbol(libSystem, "access", (void *)rep_access, (void **)&orig_access);
    VSHookSymbol(libSystem, "stat", (void *)rep_stat, (void **)&orig_stat);
    VSHookSymbol(libSystem, "lstat", (void *)rep_lstat, (void **)&orig_lstat);
    VSHookSymbol(libSystem, "statfs", (void *)rep_statfs, (void **)&orig_statfs);
    VSHookSymbol(libSystem, "statvfs", (void *)rep_statvfs, (void **)&orig_statvfs);
    VSHookSymbol(libSystem, "opendir", (void *)rep_opendir, (void **)&orig_opendir);
    VSHookSymbol(libSystem, "realpath", (void *)rep_realpath, (void **)&orig_realpath);
    VSHookSymbol(libSystem, "readlink", (void *)rep_readlink, (void **)&orig_readlink);
    VSHookSymbol(libSystem, "getxattr", (void *)rep_getxattr, (void **)&orig_getxattr);
    VSHookSymbol(libSystem, "listxattr", (void *)rep_listxattr, (void **)&orig_listxattr);
    VSHookSymbol(libSystem, "getenv", (void *)rep_getenv, (void **)&orig_getenv);
    VSHookSymbol(libSystem, "ptrace", (void *)rep_ptrace, (void **)&orig_ptrace);
    VSHookSymbol(libSystem, "csops", (void *)rep_csops, (void **)&orig_csops);
    VSHookSymbol(libSystem, "sysctlbyname", (void *)rep_sysctlbyname, (void **)&orig_sysctlbyname);
    VSHookSymbol(libSystem, "sysctl", (void *)rep_sysctl, (void **)&orig_sysctl);
}

static void VSHookMetaJailbreakExports(void) {
    int count = 0;
    count += VSHookSymbol(NULL, "METADeviceIsJailbroken", (void *)rep_METADeviceIsJailbroken, (void **)&orig_METADeviceIsJailbroken) ? 1 : 0;
    count += VSHookSymbol(NULL, "METADeviceAppearsJailbroken", (void *)rep_METADeviceAppearsJailbroken, (void **)&orig_METADeviceAppearsJailbroken) ? 1 : 0;
    count += VSHookSymbol(NULL, "IGDeviceReportWithJailbreakInfo", (void *)rep_IGDeviceReportWithJailbreakInfo, (void **)&orig_IGDeviceReportWithJailbreakInfo) ? 1 : 0;
    char buf[32];
    snprintf(buf, sizeof(buf), "%d/3", count);
    VSLogC("meta-jailbreak-hook-count", buf);
}

static void VSHookObjectiveCBasic(void) {
    VSHookInstanceMethod(NSFileManager.class, @selector(fileExistsAtPath:), (IMP)rep_NSFileManager_fileExistsAtPath, (IMP *)&orig_NSFileManager_fileExistsAtPath);
    VSHookInstanceMethod(NSFileManager.class, @selector(fileExistsAtPath:isDirectory:), (IMP)rep_NSFileManager_fileExistsAtPath_isDirectory, (IMP *)&orig_NSFileManager_fileExistsAtPath_isDirectory);
    VSHookInstanceMethod(NSFileManager.class, @selector(isReadableFileAtPath:), (IMP)rep_NSFileManager_isReadableFileAtPath, (IMP *)&orig_NSFileManager_isReadableFileAtPath);
    VSHookInstanceMethod(NSFileManager.class, @selector(isExecutableFileAtPath:), (IMP)rep_NSFileManager_isExecutableFileAtPath, (IMP *)&orig_NSFileManager_isExecutableFileAtPath);
    VSHookInstanceMethod(UIApplication.class, @selector(canOpenURL:), (IMP)rep_UIApplication_canOpenURL, (IMP *)&orig_UIApplication_canOpenURL);
    VSHookInstanceMethod(NSProcessInfo.class, @selector(environment), (IMP)rep_NSProcessInfo_environment, (IMP *)&orig_NSProcessInfo_environment);
}

static void VSHookJailbreakSelectors(void) {
    VSHookAllZeroArgSelector(@selector(isJailbroken));
    VSHookAllZeroArgSelector(@selector(jailbroken));
    VSHookAllZeroArgSelector(NSSelectorFromString(@"FBFamilyIDDeviceIsJailbroken"));
}

__attribute__((constructor))
static void VPhoneStealthTweakInit(void) {
    @autoreleasepool {
        const char *audit = getenv("VPHONE_STEALTH_AUDIT");
        VSAudit = (access("/tmp/vphone_stealth_audit", F_OK) == 0) || (audit && (
            strcmp(audit, "1") == 0 ||
            VSCStringEqualsCI(audit, "true") ||
            VSCStringEqualsCI(audit, "yes")
        ));
        const char *wide = getenv("VPHONE_STEALTH_WIDE_HOOKS");
        BOOL wideHooks = (access("/tmp/vphone_stealth_wide_hooks", F_OK) == 0) || (wide && (
            strcmp(wide, "1") == 0 ||
            VSCStringEqualsCI(wide, "true") ||
            VSCStringEqualsCI(wide, "yes")
        ));
        VSLogC("init-start", NULL);
        VSHookMetaJailbreakExports();
        VSLogC("meta-jailbreak-hooks-installed", NULL);
        if (wideHooks) {
            VSHookCFunctions();
            VSLogC("wide-c-hooks-installed", NULL);
            VSHookObjectiveCBasic();
            VSLogC("wide-objc-basic-hooks-installed", NULL);
            dispatch_async(dispatch_get_main_queue(), ^{
                VSHookJailbreakSelectors();
                VSLogC("wide-selector-hooks-installed", NULL);
            });
        } else {
            VSLogC("wide-hooks-skipped", NULL);
        }
    }
}
