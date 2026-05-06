#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/utsname.h>

static NSString *const VPStatePath = @"/tmp/instagram_account.json";
static NSString *VPBundleID;
static NSMutableSet<NSString *> *VPLoggedReads;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *VPRequestState;
static NSMutableDictionary<NSString *, NSString *> *VPLatestFieldState;
static NSLock *VPLogLock;
static NSISO8601DateFormatter *VPDateFormatter;
static NSDictionary *VPProfile;
static BOOL VPProfileLoaded;

typedef void (*MSHookFunctionType)(void *symbol, void *replace, void **result);

static void VPEmitEvent(NSString *type, NSDictionary *payload);
static void VPEmitFieldSnapshot(NSString *source, NSDictionary<NSString *, NSString *> *fields, NSDictionary *extra);

static NSDictionary *VPLoadProfile(void) {
    if (VPProfileLoaded) return VPProfile;
    VPProfileLoaded = YES;
    NSString *bundle = VPBundleID.length ? VPBundleID : (NSBundle.mainBundle.bundleIdentifier ?: @"");
    if (!bundle.length) return nil;
    NSString *name = [bundle stringByAppendingPathExtension:@"json"];
    for (NSString *root in @[ @"/var/mobile/vphone_app_profiles", @"/private/var/mobile/vphone_app_profiles" ]) {
        NSString *path = [root stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *profile = (NSDictionary *)obj;
        NSString *profileBundle = [profile[@"bundle_id"] isKindOfClass:NSString.class] ? profile[@"bundle_id"] : @"";
        if (profileBundle.length && ![profileBundle isEqualToString:bundle]) continue;
        id enabled = profile[@"enabled"];
        if ([enabled respondsToSelector:@selector(boolValue)] && ![enabled boolValue]) return nil;
        VPProfile = profile;
        return VPProfile;
    }
    return nil;
}

static NSString *VPProfileString(NSString *key) {
    id value = VPLoadProfile()[key];
    if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) return value;
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *s = [value stringValue];
        if (s.length) return s;
    }
    return nil;
}

static BOOL VPProfileBool(NSString *key, BOOL defaultValue) {
    id value = VPLoadProfile()[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : defaultValue;
}

static NSString *VPCurrentMachine(void) {
    struct utsname name;
    if (uname(&name) == 0 && name.machine[0]) return [NSString stringWithUTF8String:name.machine];
    return nil;
}

static NSString *VPProfileProductType(void) {
    return VPProfileString(@"productType") ?: VPProfileString(@"hardwareMachine");
}

static NSString *VPNormalizeUserAgentForProfile(NSString *input) {
    if (![input isKindOfClass:NSString.class] || input.length == 0) return input;
    if (!VPProfileBool(@"spoofProductType", YES)) return input;
    NSString *productType = VPProfileProductType();
    if (!productType.length) return input;

    NSString *out = input;
    NSArray<NSString *> *needles = @[
        VPProfileString(@"sourceProductType") ?: VPCurrentMachine() ?: @"",
        @"iPhone99,11"
    ];
    for (NSString *needle in needles) {
        if (!needle.length || [needle isEqualToString:productType]) continue;
        out = [out stringByReplacingOccurrencesOfString:needle withString:productType];
    }
    if (![out isEqualToString:input]) return out;
    if ([out rangeOfString:@"Instagram"].location == NSNotFound) return input;
    if ([out rangeOfString:productType].location != NSNotFound) return out;

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"iPhone[0-9]{2,3},[0-9]+"
                                                                           options:0
                                                                             error:nil];
    return [regex stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:productType];
}

static NSString *VPNowISO8601(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VPDateFormatter = [NSISO8601DateFormatter new];
        VPDateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [VPDateFormatter stringFromDate:NSDate.date];
}

static NSString *VPISO8601Date(NSDate *date) {
    if (![date isKindOfClass:NSDate.class]) return nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!VPDateFormatter) {
            VPDateFormatter = [NSISO8601DateFormatter new];
            VPDateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        }
    });
    return [VPDateFormatter stringFromDate:date];
}

static id VPJSONSafeValue(id value, NSUInteger depth) {
    if (!value) return [NSNull null];
    if (depth > 4) return [value description] ?: [NSNull null];
    if ([value isKindOfClass:NSString.class] ||
        [value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSNull.class]) {
        return value;
    }
    if ([value isKindOfClass:NSURL.class]) {
        return [(NSURL *)value absoluteString] ?: [NSNull null];
    }
    if ([value isKindOfClass:NSUUID.class]) {
        return [(NSUUID *)value UUIDString] ?: [NSNull null];
    }
    if ([value isKindOfClass:NSDate.class]) {
        return VPISO8601Date((NSDate *)value) ?: [value description] ?: [NSNull null];
    }
    if ([value isKindOfClass:NSLocale.class]) {
        return [(NSLocale *)value localeIdentifier] ?: [value description] ?: [NSNull null];
    }
    if ([value isKindOfClass:NSTimeZone.class]) {
        return [(NSTimeZone *)value name] ?: [value description] ?: [NSNull null];
    }
    if ([value isKindOfClass:NSData.class]) {
        return [(NSData *)value base64EncodedStringWithOptions:0] ?: [NSNull null];
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            [out addObject:VPJSONSafeValue(item, depth + 1) ?: [NSNull null]];
        }
        return out;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *)value) {
            NSString *keyString = [key isKindOfClass:NSString.class] ? key : [key description];
            if (!keyString.length) continue;
            out[keyString] = VPJSONSafeValue(((NSDictionary *)value)[key], depth + 1) ?: [NSNull null];
        }
        return out;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *s = [value stringValue];
        if (s.length) return s;
    }
    return [value description] ?: [NSNull null];
}

static NSDictionary *VPInterestingHeaders(NSDictionary<NSString *, NSString *> *headers) {
    if (![headers isKindOfClass:NSDictionary.class] || headers.count == 0) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        NSString *lower = key.lowercaseString ?: @"";
        if ([lower isEqualToString:@"user-agent"] ||
            [lower isEqualToString:@"cookie"] ||
            [lower isEqualToString:@"authorization"] ||
            [lower isEqualToString:@"x-mid"] ||
            [lower hasPrefix:@"x-ig-"] ||
            [lower hasPrefix:@"ig-u-"]) {
            out[key] = obj ?: @"";
        }
    }];
    return out;
}

static void VPUpdateLatestFieldState(NSDictionary<NSString *, NSString *> *fields) {
    if (![fields isKindOfClass:NSDictionary.class] || fields.count == 0) return;
    @synchronized ([NSProcessInfo processInfo]) {
        if (!VPLatestFieldState) VPLatestFieldState = [NSMutableDictionary dictionary];
        [fields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
            if (![key isKindOfClass:NSString.class] || !key.length) return;
            if (![obj isKindOfClass:NSString.class] || !obj.length) return;
            VPLatestFieldState[key] = obj;
        }];
    }
}

static NSDictionary<NSString *, NSString *> *VPCopyLatestFieldState(void) {
    @synchronized ([NSProcessInfo processInfo]) {
        return VPLatestFieldState.count ? [VPLatestFieldState copy] : @{};
    }
}

static NSDictionary<NSString *, NSString *> *VPDerivedFieldsFromAuthorization(NSString *authorization) {
    if (![authorization isKindOfClass:NSString.class] || authorization.length == 0) return @{};
    if (![authorization hasPrefix:@"Bearer IGT:"]) return @{};
    NSArray<NSString *> *parts = [authorization componentsSeparatedByString:@":"];
    NSString *payload = parts.count >= 3 ? parts.lastObject : nil;
    if (!payload.length) return @{};
    NSUInteger rem = payload.length % 4;
    if (rem != 0) {
        payload = [payload stringByPaddingToLength:payload.length + (4 - rem) withString:@"=" startingAtIndex:0];
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    if (!data.length) return @{};
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *sessionID = [json[@"sessionid"] isKindOfClass:NSString.class] ? json[@"sessionid"] : nil;
    NSString *userID = [json[@"ds_user_id"] isKindOfClass:NSString.class] ? json[@"ds_user_id"] : nil;
    if (sessionID.length) out[@"session_id"] = sessionID;
    if (userID.length) out[@"ds_user_id"] = userID;
    return out;
}

static id VPCallClassSelector(Class cls, SEL sel) {
    if (!cls || !sel || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static id VPCallInstanceSelector(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static Class VPResolveClass(NSArray<NSString *> *candidates) {
    for (NSString *name in candidates) {
        if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
        Class cls = NSClassFromString(name);
        if (cls) return cls;
    }
    return Nil;
}

static BOOL VPStringLooksLikeUUID(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    return uuid != nil;
}

static void VPWriteAccountStateFile(void) {
    NSDictionary<NSString *, NSString *> *latest = VPCopyLatestFieldState();
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"bundle_id"] = VPBundleID ?: @"";
    state[@"updated_at"] = VPNowISO8601();
    for (NSString *key in @[
        @"authorization",
        @"session_id",
        @"ds_user_id",
        @"x_ig_device_id",
        @"family_device_id",
        @"x_ig_www_claim",
        @"www_claim",
        @"x_mid",
        @"rur",
        @"fbid_v2",
        @"ig_u_rur",
        @"csrftoken",
        @"user_agent",
        @"pigeon_session_id"
    ]) {
        NSString *value = latest[key];
        if ([value isKindOfClass:NSString.class] && value.length > 0) {
            state[key] = value;
        }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
    if (!json.length) return;
    [VPLogLock lock];
    int fd = open(VPStatePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        (void)write(fd, json.bytes, json.length);
        close(fd);
    }
    [VPLogLock unlock];
}

static void VPTryPopulateStaticFields(void) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];

    Class IGUserAgentClass = VPResolveClass(@[
        @"IGUserAgent",
        @"_TtC11IGUserAgent11IGUserAgent"
    ]);
    id sharedUserAgent = VPCallClassSelector(IGUserAgentClass, @selector(shared));
    id apiRequestString = VPCallInstanceSelector(sharedUserAgent, @selector(APIRequestString));
    if (![apiRequestString isKindOfClass:NSString.class] || ![apiRequestString length]) {
        apiRequestString = VPCallClassSelector(IGUserAgentClass, @selector(staticAPIRequestString));
    }
    if ([apiRequestString isKindOfClass:NSString.class] && [apiRequestString length] > 0) {
        fields[@"user_agent"] = apiRequestString;
    }

    Class FOATokenRegistrationKitClass = VPResolveClass(@[
        @"FOATokenRegistrationKit",
        @"_TtC23FOATokenRegistrationKit23FOATokenRegistrationKit"
    ]);
    id deviceID = VPCallClassSelector(FOATokenRegistrationKitClass, @selector(getDeviceId));
    if ((![deviceID isKindOfClass:NSString.class] || ![deviceID length])) {
        typedef id (*IGDeviceIDFn)(void);
        IGDeviceIDFn igDeviceID = (IGDeviceIDFn)dlsym(RTLD_DEFAULT, "IGDeviceID");
        if (!igDeviceID) igDeviceID = (IGDeviceIDFn)dlsym(RTLD_DEFAULT, "_IGDeviceID");
        if (igDeviceID) deviceID = igDeviceID();
    }
    if ([deviceID isKindOfClass:NSString.class] && [deviceID length] > 0) {
        fields[@"x_ig_device_id"] = deviceID;
    }

    if (fields.count > 0) {
        VPEmitFieldSnapshot(@"static_probe", fields, nil);
    } else {
        VPWriteAccountStateFile();
    }
}

static void VPScheduleStaticFieldProbe(void) {
    NSArray<NSNumber *> *delays = @[ @0, @1, @3, @6 ];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VPTryPopulateStaticFields();
        });
    }
}

static NSString *VPRequestKey(id request) {
    return request ? [NSString stringWithFormat:@"%p", request] : nil;
}

static NSMutableDictionary *VPRequestStateForRequest(id request, BOOL create) {
    NSString *key = VPRequestKey(request);
    if (!key.length) return nil;
    @synchronized ([NSProcessInfo processInfo]) {
        if (!VPRequestState && create) VPRequestState = [NSMutableDictionary dictionary];
        NSMutableDictionary *state = VPRequestState[key];
        if (!state && create) {
            state = [NSMutableDictionary dictionary];
            state[@"headers"] = [NSMutableDictionary dictionary];
            VPRequestState[key] = state;
        }
        return state;
    }
}

static void VPRequestStateSetHeader(id request, NSString *field, NSString *value) {
    if (!field.length) return;
    NSMutableDictionary *state = VPRequestStateForRequest(request, YES);
    NSMutableDictionary *headers = state[@"headers"];
    if (![headers isKindOfClass:NSMutableDictionary.class]) {
        headers = [NSMutableDictionary dictionary];
        state[@"headers"] = headers;
    }
    headers[field] = value ?: @"";
}

static void VPRequestStateSetAllHeaders(id request, NSDictionary *headers) {
    if (![headers isKindOfClass:NSDictionary.class]) return;
    for (id key in headers) {
        NSString *field = [key isKindOfClass:NSString.class] ? key : [key description];
        NSString *value = [headers[key] isKindOfClass:NSString.class] ? headers[key] : [headers[key] description];
        if (field.length) VPRequestStateSetHeader(request, field, value ?: @"");
    }
}

static void VPRequestStateSetURL(id request, NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return;
    NSMutableDictionary *state = VPRequestStateForRequest(request, YES);
    state[@"url"] = url.absoluteString ?: @"";
}

static void VPRequestStateSetMethod(id request, NSString *method) {
    if (![method isKindOfClass:NSString.class] || method.length == 0) return;
    NSMutableDictionary *state = VPRequestStateForRequest(request, YES);
    state[@"method"] = method;
}

static BOOL VPURLContainsGraphQLWWW(NSURL *url) {
    NSString *text = url.absoluteString.lowercaseString ?: @"";
    return [text containsString:@"graphql_www"] || [text containsString:@"/graphql/query"];
}

static NSDictionary<NSString *, NSString *> *VPNormalizeHeaders(NSDictionary<NSString *, NSString *> *headers) {
    if (![headers isKindOfClass:NSDictionary.class] || headers.count == 0) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        if (![key isKindOfClass:NSString.class]) return;
        NSString *lower = key.lowercaseString ?: @"";
        if (!lower.length) return;
        out[lower] = [obj isKindOfClass:NSString.class] ? obj : ([obj description] ?: @"");
    }];
    return out;
}

static NSDictionary<NSString *, NSString *> *VPParseCookieHeader(NSString *cookieHeader) {
    if (![cookieHeader isKindOfClass:NSString.class] || cookieHeader.length == 0) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSArray<NSString *> *pairs = [cookieHeader componentsSeparatedByString:@";"];
    for (NSString *pair in pairs) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *name = [[pair substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        NSString *value = [[pair substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) continue;
        out[name] = value ?: @"";
    }
    return out;
}

static NSString *VPFirstValue(NSDictionary<NSString *, NSString *> *dict, NSArray<NSString *> *keys) {
    if (![dict isKindOfClass:NSDictionary.class] || dict.count == 0) return nil;
    for (NSString *key in keys) {
        NSString *value = dict[key.lowercaseString];
        if ([value isKindOfClass:NSString.class] && value.length > 0) return value;
    }
    return nil;
}

static NSDictionary *VPExtractGraphQLWWWFields(NSDictionary<NSString *, NSString *> *headers, NSDictionary<NSString *, NSString *> *cookies) {
    NSDictionary *normHeaders = VPNormalizeHeaders(headers);
    NSDictionary *cookieMap = cookies ?: @{};
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];

    NSString *xMid = VPFirstValue(normHeaders, @[ @"x-mid", @"mid" ]) ?: VPFirstValue(cookieMap, @[ @"x-mid", @"mid" ]);
    NSString *rur = VPFirstValue(cookieMap, @[ @"rur" ]);
    NSString *fbidV2 = VPFirstValue(cookieMap, @[ @"fbid_v2" ]);
    NSString *igURur = VPFirstValue(normHeaders, @[ @"ig-u-rur", @"x-ig-u-rur" ]);
    NSString *csrftoken = VPFirstValue(cookieMap, @[ @"csrftoken" ]) ?: VPFirstValue(normHeaders, @[ @"x-csrftoken", @"csrftoken" ]);
    NSString *wwwClaim = VPFirstValue(cookieMap, @[ @"www_claim", @"www-claim" ]) ?: VPFirstValue(normHeaders, @[ @"www-claim", @"x-www-claim" ]);
    NSString *dsUserID = VPFirstValue(cookieMap, @[ @"ds_user_id" ]) ?: VPFirstValue(normHeaders, @[ @"ig-u-ds-user-id", @"x-ig-ds-user-id" ]);
    NSString *sessionID = VPFirstValue(cookieMap, @[ @"sessionid", @"session_id" ]);
    NSString *userAgent = VPFirstValue(normHeaders, @[ @"user-agent" ]);
    NSString *authorization = VPFirstValue(normHeaders, @[ @"authorization" ]);
    NSString *xIGDeviceID = VPFirstValue(normHeaders, @[ @"x-ig-device-id" ]);
    NSString *xIGWWWClaim = VPFirstValue(normHeaders, @[ @"x-ig-www-claim" ]);
    NSString *familyDeviceID = VPFirstValue(normHeaders, @[ @"family_device_id", @"family-device-id", @"x-family-device-id", @"x-ig-family-device-id" ]);
    NSString *pigeonSessionID = VPFirstValue(normHeaders, @[ @"pigeon_session_id", @"pigeon-session-id", @"x-pigeon-session-id" ]);

    if (xMid.length) fields[@"x_mid"] = xMid;
    if (rur.length) fields[@"rur"] = rur;
    if (fbidV2.length) fields[@"fbid_v2"] = fbidV2;
    if (igURur.length) fields[@"ig_u_rur"] = igURur;
    if (csrftoken.length) fields[@"csrftoken"] = csrftoken;
    if (wwwClaim.length) fields[@"www_claim"] = wwwClaim;
    if (dsUserID.length) fields[@"ds_user_id"] = dsUserID;
    if (sessionID.length) fields[@"session_id"] = sessionID;
    if (userAgent.length) fields[@"user_agent"] = userAgent;
    if (authorization.length) fields[@"authorization"] = authorization;
    if (xIGDeviceID.length) fields[@"x_ig_device_id"] = xIGDeviceID;
    if (xIGWWWClaim.length) fields[@"x_ig_www_claim"] = xIGWWWClaim;
    if (familyDeviceID.length) fields[@"family_device_id"] = familyDeviceID;
    if (pigeonSessionID.length) fields[@"pigeon_session_id"] = pigeonSessionID;
    return fields;
}

static NSString *VPRegexFirstCapture(NSString *text, NSString *pattern) {
    if (![text isKindOfClass:NSString.class] || text.length == 0 || pattern.length == 0) return nil;
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:&error];
    if (!regex || error) return nil;
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    NSRange range = [match rangeAtIndex:1];
    if (range.location == NSNotFound || range.length == 0) return nil;
    return [text substringWithRange:range];
}

static NSDictionary *VPExtractGraphQLWWWResponseFields(NSHTTPURLResponse *response, NSData *data) {
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return @{};
    NSDictionary *rawHeaders = response.allHeaderFields ?: @{};
    NSDictionary *normHeaders = VPNormalizeHeaders(rawHeaders);
    NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:rawHeaders forURL:response.URL ?: [NSURL URLWithString:@"https://i.instagram.com/graphql_www"]];
    NSMutableDictionary *cookieMap = [NSMutableDictionary dictionary];
    for (NSHTTPCookie *cookie in cookies) {
        if (![cookie isKindOfClass:NSHTTPCookie.class]) continue;
        NSString *name = cookie.name.lowercaseString ?: @"";
        if (!name.length) continue;
        cookieMap[name] = cookie.value ?: @"";
    }

    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithDictionary:VPExtractGraphQLWWWFields(rawHeaders, cookieMap)];

    NSString *responseAuthorization = VPFirstValue(normHeaders, @[ @"ig-set-authorization", @"authorization" ]);
    NSString *responseIGURur = VPFirstValue(normHeaders, @[ @"ig-set-ig-u-rur", @"ig-u-rur", @"x-ig-u-rur" ]);
    NSString *responseWWWClaim = VPFirstValue(normHeaders, @[ @"x-ig-set-www-claim", @"x-ig-www-claim", @"www-claim" ]);
    if (responseAuthorization.length) fields[@"authorization"] = responseAuthorization;
    if (responseIGURur.length) fields[@"ig_u_rur"] = responseIGURur;
    if (responseWWWClaim.length) {
        fields[@"x_ig_www_claim"] = responseWWWClaim;
        if (!fields[@"www_claim"]) fields[@"www_claim"] = responseWWWClaim;
    }

    NSString *bodyText = nil;
    if ([data isKindOfClass:NSData.class] && data.length > 0) {
        bodyText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!bodyText.length) bodyText = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    NSString *fbid = VPRegexFirstCapture(bodyText, @"fbid_v2[^0-9]{0,32}([0-9]{5,})");
    if (fbid.length) fields[@"fbid_v2"] = fbid;
    return fields;
}

static void VPEmitFieldSnapshot(NSString *source, NSDictionary<NSString *, NSString *> *fields, NSDictionary *extra) {
    if (![fields isKindOfClass:NSDictionary.class] || fields.count == 0) return;
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:fields];
    NSString *authorization = fields[@"authorization"];
    NSDictionary *derived = VPDerivedFieldsFromAuthorization(authorization);
    if (derived.count) [merged addEntriesFromDictionary:derived];
    NSString *userAgent = merged[@"user_agent"];
    if ([userAgent isKindOfClass:NSString.class] && userAgent.length > 0) {
        merged[@"user_agent"] = VPNormalizeUserAgentForProfile(userAgent);
    }
    VPUpdateLatestFieldState(merged);
    VPWriteAccountStateFile();
}

static void VPEmitGraphQLWWWCapture(NSURLRequest *request, NSString *source) {
    if (![request isKindOfClass:NSURLRequest.class]) return;
    if (!VPURLContainsGraphQLWWW(request.URL)) return;
    NSDictionary *headers = request.allHTTPHeaderFields ?: @{};
    NSDictionary *cookies = VPParseCookieHeader(VPFirstValue(VPNormalizeHeaders(headers), @[ @"cookie" ]));
    NSDictionary *fields = VPExtractGraphQLWWWFields(headers, cookies);
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"source"] = source ?: @"";
    payload[@"method"] = request.HTTPMethod ?: @"GET";
    payload[@"url"] = request.URL.absoluteString ?: @"";
    payload[@"fields"] = fields ?: @{};
    payload[@"headers"] = headers;
    if (cookies.count) payload[@"cookie_map"] = cookies;
    VPEmitEvent(@"graphql_www_request", payload);
    VPEmitFieldSnapshot(source ?: @"graphql_www_request", fields, @{
        @"url": request.URL.absoluteString ?: @"",
        @"method": request.HTTPMethod ?: @"GET",
    });
}

static void VPMaybeEmitGraphQLWWWRequestFromState(id request, NSString *source) {
    NSMutableDictionary *state = VPRequestStateForRequest(request, NO);
    if (![state isKindOfClass:NSDictionary.class]) return;
    if ([state[@"graphql_emitted"] boolValue]) return;
    NSString *urlString = state[@"url"];
    NSURL *url = [urlString isKindOfClass:NSString.class] ? [NSURL URLWithString:urlString] : nil;
    if (!VPURLContainsGraphQLWWW(url)) return;
    NSDictionary *headers = state[@"headers"];
    NSDictionary *cookies = VPParseCookieHeader(VPFirstValue(VPNormalizeHeaders(headers), @[ @"cookie" ]));
    NSDictionary *fields = VPExtractGraphQLWWWFields(headers, cookies);
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"source"] = source ?: @"state";
    payload[@"method"] = state[@"method"] ?: @"GET";
    payload[@"url"] = url.absoluteString ?: @"";
    payload[@"fields"] = fields ?: @{};
    payload[@"headers"] = headers ?: @{};
    if (cookies.count) payload[@"cookie_map"] = cookies;
    VPEmitEvent(@"graphql_www_request", payload);
    VPEmitFieldSnapshot(source ?: @"state", fields, @{
        @"url": url.absoluteString ?: @"",
        @"method": state[@"method"] ?: @"GET",
    });
    state[@"graphql_emitted"] = @YES;
}

static void VPEmitInstagramCookieSnapshot(NSURL *url, NSArray *cookies, NSString *source) {
    NSString *host = url.host.lowercaseString ?: @"";
    if (![host containsString:@"instagram"]) return;
    NSMutableDictionary *cookieMap = [NSMutableDictionary dictionary];
    for (id obj in cookies) {
        if (![obj isKindOfClass:NSHTTPCookie.class]) continue;
        NSHTTPCookie *cookie = (NSHTTPCookie *)obj;
        NSString *name = cookie.name.lowercaseString ?: @"";
        if (!name.length) continue;
        cookieMap[name] = cookie.value ?: @"";
    }
    NSDictionary *fields = VPExtractGraphQLWWWFields(@{}, cookieMap);
    if (fields.count == 0) return;
    VPEmitEvent(@"instagram_cookie_snapshot", @{
        @"source": source ?: @"",
        @"url": url.absoluteString ?: @"",
        @"fields": fields,
        @"cookie_map": cookieMap,
    });
    VPEmitFieldSnapshot(source ?: @"cookie_snapshot", fields, @{
        @"url": url.absoluteString ?: @"",
    });
}

static void VPEmitGraphQLWWWResponse(NSURLRequest *request, NSURLResponse *response, NSData *data, NSError *error, NSString *source) {
    if (![request isKindOfClass:NSURLRequest.class] || !VPURLContainsGraphQLWWW(request.URL)) return;
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"source"] = source ?: @"";
    payload[@"method"] = request.HTTPMethod ?: @"GET";
    payload[@"url"] = request.URL.absoluteString ?: @"";
    if (http) payload[@"status_code"] = @(http.statusCode);
    if (error) payload[@"error"] = error.localizedDescription ?: @"";
    NSDictionary *fields = VPExtractGraphQLWWWResponseFields(http, data);
    payload[@"fields"] = fields ?: @{};
    if (http.allHeaderFields.count) payload[@"response_headers"] = http.allHeaderFields;
    if ([data isKindOfClass:NSData.class]) payload[@"body_length"] = @(data.length);
    VPEmitEvent(@"graphql_www_response", payload);
    VPEmitFieldSnapshot(source ?: @"graphql_www_response", fields, @{
        @"url": request.URL.absoluteString ?: @"",
        @"method": request.HTTPMethod ?: @"GET",
        @"status_code": http ? @(http.statusCode) : @0,
    });
}

static void VPCollectInterestingJSONStrings(id obj, NSMutableArray<NSString *> *out, NSUInteger depth) {
    if (!obj || depth > 8) return;
    if ([obj isKindOfClass:NSString.class]) {
        NSString *text = (NSString *)obj;
        if ([text containsString:@"IG-Set-Authorization"] ||
            [text containsString:@"Set-Cookie:"] ||
            [text containsString:@"x-ig-set-www-claim"] ||
            [text containsString:@"ig-set-ig-u-rur"] ||
            [text containsString:@"fbid_v2"]) {
            [out addObject:text];
        }
        return;
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (id value in [(NSDictionary *)obj allValues]) {
            VPCollectInterestingJSONStrings(value, out, depth + 1);
        }
        return;
    }
    if ([obj isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)obj) {
            VPCollectInterestingJSONStrings(value, out, depth + 1);
        }
    }
}

static NSDictionary *VPExtractFieldsFromInterestingStrings(NSArray<NSString *> *strings) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSString *text in strings) {
        if (![text isKindOfClass:NSString.class] || text.length == 0) continue;
        NSString *authorization = VPRegexFirstCapture(text, @"IG-Set-Authorization\\\"?\\s*[:=]\\s*\\\"([^\\\"]+)");
        NSString *igURur = VPRegexFirstCapture(text, @"ig-set-ig-u-rur\\\"?\\s*[:=]\\s*\\\"([^\\\"]+)");
        NSString *wwwClaim = VPRegexFirstCapture(text, @"x-ig-set-www-claim\\\"?\\s*[:=]\\s*\\\"([^\\\"]+)");
        NSString *fbid = VPRegexFirstCapture(text, @"fbid_v2[^0-9]{0,32}([0-9]{5,})");
        if (authorization.length) fields[@"authorization"] = authorization;
        if (igURur.length) fields[@"ig_u_rur"] = igURur;
        if (wwwClaim.length) {
            fields[@"x_ig_www_claim"] = wwwClaim;
            if (!fields[@"www_claim"]) fields[@"www_claim"] = wwwClaim;
        }
        if (fbid.length) fields[@"fbid_v2"] = fbid;

        NSArray<NSString *> *cookieLines = [text componentsSeparatedByString:@"Set-Cookie:"];
        for (NSString *line in cookieLines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!trimmed.length) continue;
            NSRange eq = [trimmed rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *name = [[trimmed substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
            NSString *rest = [trimmed substringFromIndex:eq.location + 1];
            NSString *value = [[rest componentsSeparatedByString:@";"] firstObject];
            if ([name isEqualToString:@"csrftoken"]) fields[@"csrftoken"] = value ?: @"";
            else if ([name isEqualToString:@"ds_user_id"]) fields[@"ds_user_id"] = value ?: @"";
            else if ([name isEqualToString:@"sessionid"] || [name isEqualToString:@"session_id"]) fields[@"session_id"] = value ?: @"";
            else if ([name isEqualToString:@"rur"]) fields[@"rur"] = value ?: @"";
            else if ([name isEqualToString:@"fbid_v2"]) fields[@"fbid_v2"] = value ?: @"";
        }
    }
    return fields;
}

static void VPAppendJSONLine(NSDictionary *event) {
    (void)event;
}

static void VPEmitEvent(NSString *type, NSDictionary *payload) {
    (void)type;
    (void)payload;
}

static void VPEmitDeviceReadOnce(NSString *api, id value, NSDictionary *extra) {
    if (!api.length) return;
    NSString *signature = [NSString stringWithFormat:@"%@|%@", api, [VPJSONSafeValue(value, 0) description] ?: @"<null>"];
    @synchronized ([NSProcessInfo processInfo]) {
        if (!VPLoggedReads) VPLoggedReads = [NSMutableSet set];
        if ([VPLoggedReads containsObject:signature]) return;
        [VPLoggedReads addObject:signature];
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"api"] = api;
    payload[@"value"] = VPJSONSafeValue(value, 0) ?: [NSNull null];
    if ([extra isKindOfClass:NSDictionary.class]) {
        [payload addEntriesFromDictionary:extra];
    }
    VPEmitEvent(@"device_read", payload);
}

static BOOL VPShouldInit(void) {
    VPBundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (!VPBundleID.length) return NO;
    return [VPBundleID isEqualToString:@"com.burbn.instagram"];
}

static NSDictionary *VPRequestPayload(NSURLRequest *request, NSString *source) {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"source"] = source ?: @"";
    payload[@"method"] = request.HTTPMethod ?: @"GET";
    payload[@"url"] = request.URL.absoluteString ?: @"";
    NSDictionary *headers = request.allHTTPHeaderFields ?: @{};
    payload[@"headers"] = headers;
    NSDictionary *interesting = VPInterestingHeaders(headers);
    if (interesting.count) payload[@"interesting_headers"] = interesting;
    return payload;
}

static void VPLogMutableHeaderChange(id request, NSString *op, NSString *field, NSString *value) {
    if (!field.length) return;
    NSString *lower = field.lowercaseString ?: @"";
    if (!([lower isEqualToString:@"user-agent"] ||
          [lower isEqualToString:@"cookie"] ||
          [lower isEqualToString:@"authorization"] ||
          [lower isEqualToString:@"x-mid"] ||
          [lower hasPrefix:@"x-ig-"] ||
          [lower hasPrefix:@"ig-u-"])) {
        return;
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"op"] = op ?: @"set";
    payload[@"field"] = field ?: @"";
    payload[@"value"] = value ?: @"";
    if ([request respondsToSelector:@selector(URL)]) {
        NSURL *url = [request URL];
        if (url.absoluteString.length) payload[@"url"] = url.absoluteString;
    }
    if ([request respondsToSelector:@selector(HTTPMethod)]) {
        NSString *method = [request HTTPMethod];
        if (method.length) payload[@"method"] = method;
    }
    VPEmitEvent(@"request_header_mutation", payload);
}

static void VPLogCookieEvent(NSString *type, NSHTTPCookie *cookie, NSURL *url) {
    if (![cookie isKindOfClass:NSHTTPCookie.class]) return;
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"name"] = cookie.name ?: @"";
    payload[@"value"] = cookie.value ?: @"";
    payload[@"domain"] = cookie.domain ?: @"";
    payload[@"path"] = cookie.path ?: @"";
    if (cookie.expiresDate) payload[@"expires"] = VPISO8601Date(cookie.expiresDate) ?: [NSNull null];
    if (url.absoluteString.length) payload[@"url"] = url.absoluteString;
    VPEmitEvent(type, payload);
}

static void VPHookInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *orig) {
    if (!cls || !sel || !replacement || !orig) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == replacement) return;
    *orig = current;
    method_setImplementation(method, replacement);
}

static void VPHookClassMethod(Class cls, SEL sel, IMP replacement, IMP *orig) {
    if (!cls) return;
    VPHookInstanceMethod(object_getClass(cls), sel, replacement, orig);
}

static Class VPClass(NSString *name) {
    return name.length ? NSClassFromString(name) : Nil;
}

static NSURL *VPRequestURLObject(id request) {
    if (!request) return nil;
    if ([request respondsToSelector:@selector(URL)]) {
        id url = ((id (*)(id, SEL))objc_msgSend)(request, @selector(URL));
        if ([url isKindOfClass:NSURL.class]) return url;
    }
    id viaKVC = nil;
    @try { viaKVC = [request valueForKey:@"URL"]; } @catch (__unused NSException *e) {}
    return [viaKVC isKindOfClass:NSURL.class] ? viaKVC : nil;
}

static NSString *VPRequestHTTPMethodObject(id request) {
    if (!request) return nil;
    if ([request respondsToSelector:@selector(HTTPMethod)]) {
        id method = ((id (*)(id, SEL))objc_msgSend)(request, @selector(HTTPMethod));
        if ([method isKindOfClass:NSString.class]) return method;
    }
    id viaKVC = nil;
    @try { viaKVC = [request valueForKey:@"HTTPMethod"]; } @catch (__unused NSException *e) {}
    return [viaKVC isKindOfClass:NSString.class] ? viaKVC : nil;
}

static NSDictionary *VPRequestHeadersObject(id request) {
    if (!request) return @{};
    if ([request respondsToSelector:@selector(allHTTPHeaderFields)]) {
        id headers = ((id (*)(id, SEL))objc_msgSend)(request, @selector(allHTTPHeaderFields));
        if ([headers isKindOfClass:NSDictionary.class]) return headers;
    }
    id viaKVC = nil;
    @try { viaKVC = [request valueForKey:@"allHTTPHeaderFields"]; } @catch (__unused NSException *e) {}
    return [viaKVC isKindOfClass:NSDictionary.class] ? viaKVC : @{};
}

static void VPEmitGraphQLWWWFromIGRequestObject(id request, NSString *source) {
    NSURL *url = VPRequestURLObject(request);
    NSDictionary *headers = VPRequestHeadersObject(request);
    NSString *method = VPRequestHTTPMethodObject(request) ?: @"GET";
    NSDictionary *cookies = VPParseCookieHeader(VPFirstValue(VPNormalizeHeaders(headers), @[ @"cookie" ]));
    NSDictionary *fields = VPExtractGraphQLWWWFields(headers, cookies);
    if (!VPURLContainsGraphQLWWW(url) && fields.count == 0) return;
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"source"] = source ?: @"request_object";
    payload[@"method"] = method;
    payload[@"url"] = url.absoluteString ?: @"";
    payload[@"fields"] = fields ?: @{};
    if (headers.count) payload[@"headers"] = headers;
    if (cookies.count) payload[@"cookie_map"] = cookies;
    VPEmitEvent(@"graphql_www_request", payload);
    VPEmitFieldSnapshot(source ?: @"request_object", fields, @{
        @"url": url.absoluteString ?: @"",
        @"method": method,
    });
}

static void (*orig_MutableRequest_setValue)(id, SEL, NSString *, NSString *);
static void rep_MutableRequest_setValue(id self, SEL _cmd, NSString *value, NSString *field) {
    VPRequestStateSetHeader(self, field, value);
    VPLogMutableHeaderChange(self, @"setValue", field, value);
    if (orig_MutableRequest_setValue) orig_MutableRequest_setValue(self, _cmd, value, field);
    VPMaybeEmitGraphQLWWWRequestFromState(self, NSStringFromSelector(_cmd));
}

static void (*orig_MutableRequest_addValue)(id, SEL, NSString *, NSString *);
static void rep_MutableRequest_addValue(id self, SEL _cmd, NSString *value, NSString *field) {
    VPRequestStateSetHeader(self, field, value);
    VPLogMutableHeaderChange(self, @"addValue", field, value);
    if (orig_MutableRequest_addValue) orig_MutableRequest_addValue(self, _cmd, value, field);
    VPMaybeEmitGraphQLWWWRequestFromState(self, NSStringFromSelector(_cmd));
}

static void (*orig_MutableRequest_setAllHTTPHeaderFields)(id, SEL, NSDictionary *);
static void rep_MutableRequest_setAllHTTPHeaderFields(id self, SEL _cmd, NSDictionary *headers) {
    VPRequestStateSetAllHeaders(self, headers);
    NSDictionary *interesting = VPInterestingHeaders(headers ?: @{});
    if (interesting.count) {
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        payload[@"op"] = @"setAllHTTPHeaderFields";
        payload[@"headers"] = headers ?: @{};
        payload[@"interesting_headers"] = interesting;
        if ([self respondsToSelector:@selector(URL)]) {
            NSURL *url = [self URL];
            if (url.absoluteString.length) payload[@"url"] = url.absoluteString;
        }
        if ([self respondsToSelector:@selector(HTTPMethod)]) {
            NSString *method = [self HTTPMethod];
            if (method.length) payload[@"method"] = method;
        }
        VPEmitEvent(@"request_header_mutation", payload);
    }
    if (orig_MutableRequest_setAllHTTPHeaderFields) orig_MutableRequest_setAllHTTPHeaderFields(self, _cmd, headers);
}

static void (*orig_MutableRequest_setURL)(id, SEL, NSURL *);
static void rep_MutableRequest_setURL(id self, SEL _cmd, NSURL *url) {
    VPRequestStateSetURL(self, url);
    if (orig_MutableRequest_setURL) orig_MutableRequest_setURL(self, _cmd, url);
    VPMaybeEmitGraphQLWWWRequestFromState(self, NSStringFromSelector(_cmd));
}

static void (*orig_MutableRequest_setHTTPMethod)(id, SEL, NSString *);
static void rep_MutableRequest_setHTTPMethod(id self, SEL _cmd, NSString *method) {
    VPRequestStateSetMethod(self, method);
    if (orig_MutableRequest_setHTTPMethod) orig_MutableRequest_setHTTPMethod(self, _cmd, method);
    VPMaybeEmitGraphQLWWWRequestFromState(self, NSStringFromSelector(_cmd));
}

static id (*orig_IGScopedNetworker_routingHeadersWithRequest)(id, SEL, id);
static id rep_IGScopedNetworker_routingHeadersWithRequest(id self, SEL _cmd, id request) {
    id result = orig_IGScopedNetworker_routingHeadersWithRequest ? orig_IGScopedNetworker_routingHeadersWithRequest(self, _cmd, request) : nil;
    if ([result isKindOfClass:NSDictionary.class]) {
        NSDictionary *headers = (NSDictionary *)result;
        NSDictionary *fields = VPExtractGraphQLWWWFields(headers, @{});
        if (fields.count > 0) {
            VPEmitEvent(@"graphql_www_request", @{
                @"source": @"IGScopedNetworker.routingHeadersWithRequest",
                @"url": VPRequestURLObject(request).absoluteString ?: @"",
                @"fields": fields,
                @"headers": headers,
            });
            VPEmitFieldSnapshot(@"IGScopedNetworker.routingHeadersWithRequest", fields, @{
                @"url": VPRequestURLObject(request).absoluteString ?: @"",
            });
        }
    }
    return result;
}

static id (*orig_IGScopedNetworker_APIHeadersAsCookies)(id, SEL);
static id rep_IGScopedNetworker_APIHeadersAsCookies(id self, SEL _cmd) {
    id result = orig_IGScopedNetworker_APIHeadersAsCookies ? orig_IGScopedNetworker_APIHeadersAsCookies(self, _cmd) : nil;
    NSDictionary *cookies = nil;
    if ([result isKindOfClass:NSString.class]) {
        cookies = VPParseCookieHeader((NSString *)result);
    } else if ([result isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *cookieMap = [NSMutableDictionary dictionary];
        [(NSDictionary *)result enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            NSString *k = [key isKindOfClass:NSString.class] ? [key lowercaseString] : [[key description] lowercaseString];
            NSString *v = [obj isKindOfClass:NSString.class] ? obj : [obj description];
            if (k.length && v.length) cookieMap[k] = v;
        }];
        cookies = cookieMap;
    }
    NSDictionary *fields = VPExtractGraphQLWWWFields(@{}, cookies ?: @{});
    if (fields.count > 0) {
        VPEmitEvent(@"instagram_cookie_snapshot", @{
            @"source": @"IGScopedNetworker.APIHeadersAsCookies",
            @"fields": fields,
            @"cookie_map": cookies ?: @{},
        });
        VPEmitFieldSnapshot(@"IGScopedNetworker.APIHeadersAsCookies", fields, nil);
    }
    return result;
}

static id (*orig_IGUserAuthHeaderManager_authHeader)(id, SEL);
static id rep_IGUserAuthHeaderManager_authHeader(id self, SEL _cmd) {
    id result = orig_IGUserAuthHeaderManager_authHeader ? orig_IGUserAuthHeaderManager_authHeader(self, _cmd) : nil;
    if ([result isKindOfClass:NSString.class] && [result length] > 0) {
        NSDictionary *fields = @{ @"authorization": result };
        VPEmitFieldSnapshot(@"IGUserAuthHeaderManager.authHeader", fields, nil);
    }
    return result;
}

static id (*orig_IGUserAuthHeaderManager_loggingClaimHeader)(id, SEL);
static id rep_IGUserAuthHeaderManager_loggingClaimHeader(id self, SEL _cmd) {
    id result = orig_IGUserAuthHeaderManager_loggingClaimHeader ? orig_IGUserAuthHeaderManager_loggingClaimHeader(self, _cmd) : nil;
    if ([result isKindOfClass:NSString.class] && [result length] > 0) {
        NSDictionary *fields = @{ @"x_ig_www_claim": result, @"www_claim": result };
        VPEmitFieldSnapshot(@"IGUserAuthHeaderManager.loggingClaimHeader", fields, nil);
    }
    return result;
}

static id (*orig_IGDeviceHeader_header)(id, SEL);
static id rep_IGDeviceHeader_header(id self, SEL _cmd) {
    id result = orig_IGDeviceHeader_header ? orig_IGDeviceHeader_header(self, _cmd) : nil;
    if ([result isKindOfClass:NSString.class] && [result length] > 0) {
        NSString *value = (NSString *)result;
        if (VPStringLooksLikeUUID(value)) {
            VPEmitFieldSnapshot(@"IGDeviceHeader.header", @{ @"x_ig_device_id": value }, nil);
        } else {
            VPEmitFieldSnapshot(@"IGDeviceHeader.header", @{ @"x_mid": value }, nil);
        }
    }
    return result;
}

static id (*orig_IGDeviceHeader_deviceHeader)(id, SEL);
static id rep_IGDeviceHeader_deviceHeader(id self, SEL _cmd) {
    id result = orig_IGDeviceHeader_deviceHeader ? orig_IGDeviceHeader_deviceHeader(self, _cmd) : nil;
    if ([result isKindOfClass:NSString.class] && [result length] > 0) {
        NSString *value = (NSString *)result;
        if (VPStringLooksLikeUUID(value)) {
            VPEmitFieldSnapshot(@"IGDeviceHeader.deviceHeader", @{ @"x_ig_device_id": value }, nil);
        } else {
            VPEmitFieldSnapshot(@"IGDeviceHeader.deviceHeader", @{ @"x_mid": value }, nil);
        }
    }
    return result;
}

static void (*orig_IGDeviceHeader_setHeader)(id, SEL, NSString *);
static void rep_IGDeviceHeader_setHeader(id self, SEL _cmd, NSString *value) {
    if ([value isKindOfClass:NSString.class] && value.length > 0) {
        if (VPStringLooksLikeUUID(value)) {
            VPEmitFieldSnapshot(@"IGDeviceHeader.setHeader", @{ @"x_ig_device_id": value }, nil);
        } else {
            VPEmitFieldSnapshot(@"IGDeviceHeader.setHeader", @{ @"x_mid": value }, nil);
        }
    }
    if (orig_IGDeviceHeader_setHeader) orig_IGDeviceHeader_setHeader(self, _cmd, value);
}

static id (*orig_IGUserAgent_commonHeaders)(id, SEL);
static id rep_IGUserAgent_commonHeaders(id self, SEL _cmd) {
    id result = orig_IGUserAgent_commonHeaders ? orig_IGUserAgent_commonHeaders(self, _cmd) : nil;
    if ([result isKindOfClass:NSDictionary.class]) {
        NSDictionary *headers = (NSDictionary *)result;
        NSString *userAgent = nil;
        NSString *pigeonSession = nil;
        for (id key in headers) {
            if (![key isKindOfClass:NSString.class]) continue;
            NSString *lower = [(NSString *)key lowercaseString];
            NSString *value = [headers[key] isKindOfClass:NSString.class] ? headers[key] : [headers[key] description];
            if (!value.length) continue;
            if ([lower isEqualToString:@"user-agent"]) userAgent = value;
            else if ([lower isEqualToString:@"x-pigeon-session-id"]) pigeonSession = value;
        }
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        if (userAgent.length) fields[@"user_agent"] = userAgent;
        if (pigeonSession.length) fields[@"pigeon_session_id"] = pigeonSession;
        if (fields.count > 0) {
            VPEmitFieldSnapshot(@"IGUserAgent.commonHeaders", fields, nil);
        }
    }
    return result;
}

static id (*orig_FBFamilySharedUserDefaultsLightImpl_familyDeviceId)(id, SEL);
static id rep_FBFamilySharedUserDefaultsLightImpl_familyDeviceId(id self, SEL _cmd) {
    id result = orig_FBFamilySharedUserDefaultsLightImpl_familyDeviceId ? orig_FBFamilySharedUserDefaultsLightImpl_familyDeviceId(self, _cmd) : nil;
    if ([result isKindOfClass:NSString.class] && [result length] > 0) {
        VPEmitFieldSnapshot(@"FBFamilySharedUserDefaultsLightImpl.familyDeviceId", @{ @"family_device_id": result }, nil);
    }
    return result;
}

static id (*orig_IGUserAgent_APIRequestString)(id, SEL);
static id rep_IGUserAgent_APIRequestString(id self, SEL _cmd) {
    id result = orig_IGUserAgent_APIRequestString ? orig_IGUserAgent_APIRequestString(self, _cmd) : nil;
    if ([result isKindOfClass:NSString.class] && [result length] > 0) {
        VPEmitFieldSnapshot(@"IGUserAgent.APIRequestString", @{ @"user_agent": result }, nil);
    }
    return result;
}

static id (*orig_IGUserAgent_staticAPIRequestString)(id, SEL);
static id rep_IGUserAgent_staticAPIRequestString(id self, SEL _cmd) {
    id result = orig_IGUserAgent_staticAPIRequestString ? orig_IGUserAgent_staticAPIRequestString(self, _cmd) : nil;
    if ([result isKindOfClass:NSString.class] && [result length] > 0) {
        VPEmitFieldSnapshot(@"IGUserAgent.staticAPIRequestString", @{ @"user_agent": result }, nil);
    }
    return result;
}

static id (*orig_FOATokenRegistrationKit_getDeviceId)(id, SEL);
static id rep_FOATokenRegistrationKit_getDeviceId(id self, SEL _cmd) {
    id result = orig_FOATokenRegistrationKit_getDeviceId ? orig_FOATokenRegistrationKit_getDeviceId(self, _cmd) : nil;
    if ([result isKindOfClass:NSString.class] && [result length] > 0) {
        VPEmitFieldSnapshot(@"FOATokenRegistrationKit.getDeviceId", @{ @"x_ig_device_id": result }, nil);
    }
    return result;
}

static void (*orig_SessionConfig_setHTTPAdditionalHeaders)(id, SEL, id);
static void rep_SessionConfig_setHTTPAdditionalHeaders(id self, SEL _cmd, id headers) {
    if ([headers isKindOfClass:NSDictionary.class]) {
        NSDictionary *interesting = VPInterestingHeaders(headers);
        if (interesting.count) {
            VPEmitEvent(@"session_http_additional_headers", @{
                @"headers": headers,
                @"interesting_headers": interesting,
            });
        }
    }
    if (orig_SessionConfig_setHTTPAdditionalHeaders) orig_SessionConfig_setHTTPAdditionalHeaders(self, _cmd, headers);
}

static id (*orig_URLSession_dataTask)(id, SEL, NSURLRequest *, id);
static id rep_URLSession_dataTask(id self, SEL _cmd, NSURLRequest *request, id completion) {
    if ([request isKindOfClass:NSURLRequest.class]) {
        VPEmitEvent(@"request", VPRequestPayload(request, NSStringFromSelector(_cmd)));
        VPEmitGraphQLWWWCapture(request, NSStringFromSelector(_cmd));
    }
    id wrappedCompletion = completion;
    if (completion) {
        void (^origBlock)(NSData *, NSURLResponse *, NSError *) = [completion copy];
        __block NSURLRequest *capturedRequest = request;
        wrappedCompletion = [^(NSData *data, NSURLResponse *response, NSError *error) {
            VPEmitGraphQLWWWResponse(capturedRequest, response, data, error, NSStringFromSelector(_cmd));
            origBlock(data, response, error);
        } copy];
    }
    return orig_URLSession_dataTask ? orig_URLSession_dataTask(self, _cmd, request, wrappedCompletion) : nil;
}

static id (*orig_URLSession_uploadTask)(id, SEL, NSURLRequest *, NSData *, id);
static id rep_URLSession_uploadTask(id self, SEL _cmd, NSURLRequest *request, NSData *body, id completion) {
    if ([request isKindOfClass:NSURLRequest.class]) {
        NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:VPRequestPayload(request, NSStringFromSelector(_cmd))];
        payload[@"body_length"] = @(body.length);
        VPEmitEvent(@"request", payload);
        VPEmitGraphQLWWWCapture(request, NSStringFromSelector(_cmd));
    }
    id wrappedCompletion = completion;
    if (completion) {
        void (^origBlock)(NSData *, NSURLResponse *, NSError *) = [completion copy];
        __block NSURLRequest *capturedRequest = request;
        wrappedCompletion = [^(NSData *data, NSURLResponse *response, NSError *error) {
            VPEmitGraphQLWWWResponse(capturedRequest, response, data, error, NSStringFromSelector(_cmd));
            origBlock(data, response, error);
        } copy];
    }
    return orig_URLSession_uploadTask ? orig_URLSession_uploadTask(self, _cmd, request, body, wrappedCompletion) : nil;
}

static id (*orig_URLSession_downloadTask)(id, SEL, NSURLRequest *, id);
static id rep_URLSession_downloadTask(id self, SEL _cmd, NSURLRequest *request, id completion) {
    if ([request isKindOfClass:NSURLRequest.class]) {
        VPEmitEvent(@"request", VPRequestPayload(request, NSStringFromSelector(_cmd)));
        VPEmitGraphQLWWWCapture(request, NSStringFromSelector(_cmd));
    }
    return orig_URLSession_downloadTask ? orig_URLSession_downloadTask(self, _cmd, request, completion) : nil;
}

static void (*orig_CookieStorage_setCookie)(id, SEL, NSHTTPCookie *);
static void rep_CookieStorage_setCookie(id self, SEL _cmd, NSHTTPCookie *cookie) {
    VPLogCookieEvent(@"set_cookie", cookie, nil);
    if (orig_CookieStorage_setCookie) orig_CookieStorage_setCookie(self, _cmd, cookie);
}

static void (*orig_CookieStorage_deleteCookie)(id, SEL, NSHTTPCookie *);
static void rep_CookieStorage_deleteCookie(id self, SEL _cmd, NSHTTPCookie *cookie) {
    VPLogCookieEvent(@"delete_cookie", cookie, nil);
    if (orig_CookieStorage_deleteCookie) orig_CookieStorage_deleteCookie(self, _cmd, cookie);
}

static id (*orig_CookieStorage_cookiesForURL)(id, SEL, NSURL *);
static id rep_CookieStorage_cookiesForURL(id self, SEL _cmd, NSURL *url) {
    id result = orig_CookieStorage_cookiesForURL ? orig_CookieStorage_cookiesForURL(self, _cmd, url) : nil;
    NSMutableArray *cookies = [NSMutableArray array];
    if ([result isKindOfClass:NSArray.class]) {
        for (id obj in (NSArray *)result) {
            if (![obj isKindOfClass:NSHTTPCookie.class]) continue;
            NSHTTPCookie *cookie = (NSHTTPCookie *)obj;
            [cookies addObject:@{
                @"name": cookie.name ?: @"",
                @"value": cookie.value ?: @"",
                @"domain": cookie.domain ?: @"",
                @"path": cookie.path ?: @"",
            }];
        }
    }
    VPEmitEvent(@"cookies_for_url", @{
        @"url": url.absoluteString ?: @"",
        @"cookies": cookies,
    });
    VPEmitInstagramCookieSnapshot(url, result, NSStringFromSelector(_cmd));
    return result;
}

static id (*orig_NSHTTPCookie_cookiesWithResponseHeaderFields)(id, SEL, NSDictionary *, NSURL *);
static id rep_NSHTTPCookie_cookiesWithResponseHeaderFields(id self, SEL _cmd, NSDictionary *headers, NSURL *url) {
    id result = orig_NSHTTPCookie_cookiesWithResponseHeaderFields ? orig_NSHTTPCookie_cookiesWithResponseHeaderFields(self, _cmd, headers, url) : nil;
    if ([result isKindOfClass:NSArray.class]) {
        for (id obj in (NSArray *)result) {
            if (![obj isKindOfClass:NSHTTPCookie.class]) continue;
            VPLogCookieEvent(@"response_cookie", (NSHTTPCookie *)obj, url);
        }
    }
    return result;
}

static id (*orig_NSJSONSerialization_JSONObjectWithData)(id, SEL, NSData *, NSJSONReadingOptions, NSError **);
static id rep_NSJSONSerialization_JSONObjectWithData(id self, SEL _cmd, NSData *data, NSJSONReadingOptions options, NSError **error) {
    id result = orig_NSJSONSerialization_JSONObjectWithData ? orig_NSJSONSerialization_JSONObjectWithData(self, _cmd, data, options, error) : nil;
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    VPCollectInterestingJSONStrings(result, strings, 0);
    NSDictionary *fields = VPExtractFieldsFromInterestingStrings(strings);
    if (fields.count > 0) {
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        payload[@"fields"] = fields;
        payload[@"string_count"] = @(strings.count);
        if ([data isKindOfClass:NSData.class]) payload[@"body_length"] = @(data.length);
        if (strings.count > 0) payload[@"matched_strings"] = strings;
        VPEmitEvent(@"graphql_www_response", payload);
        VPEmitFieldSnapshot(@"NSJSONSerialization", fields, @{
            @"body_length": [data isKindOfClass:NSData.class] ? @(data.length) : @0,
        });
    }
    return result;
}

static id (*orig_UIDevice_name)(id, SEL);
static id rep_UIDevice_name(id self, SEL _cmd) {
    id value = orig_UIDevice_name ? orig_UIDevice_name(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"UIDevice.name", value, nil);
    return value;
}

static id (*orig_UIDevice_model)(id, SEL);
static id rep_UIDevice_model(id self, SEL _cmd) {
    id value = orig_UIDevice_model ? orig_UIDevice_model(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"UIDevice.model", value, nil);
    return value;
}

static id (*orig_UIDevice_localizedModel)(id, SEL);
static id rep_UIDevice_localizedModel(id self, SEL _cmd) {
    id value = orig_UIDevice_localizedModel ? orig_UIDevice_localizedModel(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"UIDevice.localizedModel", value, nil);
    return value;
}

static id (*orig_UIDevice_systemName)(id, SEL);
static id rep_UIDevice_systemName(id self, SEL _cmd) {
    id value = orig_UIDevice_systemName ? orig_UIDevice_systemName(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"UIDevice.systemName", value, nil);
    return value;
}

static id (*orig_UIDevice_systemVersion)(id, SEL);
static id rep_UIDevice_systemVersion(id self, SEL _cmd) {
    id value = orig_UIDevice_systemVersion ? orig_UIDevice_systemVersion(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"UIDevice.systemVersion", value, nil);
    return value;
}

static id (*orig_UIDevice_identifierForVendor)(id, SEL);
static id rep_UIDevice_identifierForVendor(id self, SEL _cmd) {
    id value = orig_UIDevice_identifierForVendor ? orig_UIDevice_identifierForVendor(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"UIDevice.identifierForVendor", value, nil);
    return value;
}

static id (*orig_AS_advertisingIdentifier)(id, SEL);
static id rep_AS_advertisingIdentifier(id self, SEL _cmd) {
    id value = orig_AS_advertisingIdentifier ? orig_AS_advertisingIdentifier(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"ASIdentifierManager.advertisingIdentifier", value, nil);
    return value;
}

static BOOL (*orig_AS_isAdvertisingTrackingEnabled)(id, SEL);
static BOOL rep_AS_isAdvertisingTrackingEnabled(id self, SEL _cmd) {
    BOOL value = orig_AS_isAdvertisingTrackingEnabled ? orig_AS_isAdvertisingTrackingEnabled(self, _cmd) : NO;
    VPEmitDeviceReadOnce(@"ASIdentifierManager.isAdvertisingTrackingEnabled", @(value), nil);
    return value;
}

static NSInteger (*orig_ATT_trackingAuthorizationStatus)(id, SEL);
static NSInteger rep_ATT_trackingAuthorizationStatus(id self, SEL _cmd) {
    NSInteger value = orig_ATT_trackingAuthorizationStatus ? orig_ATT_trackingAuthorizationStatus(self, _cmd) : 0;
    VPEmitDeviceReadOnce(@"ATTrackingManager.trackingAuthorizationStatus", @(value), nil);
    return value;
}

static id (*orig_NSLocale_currentLocale)(id, SEL);
static id rep_NSLocale_currentLocale(id self, SEL _cmd) {
    id value = orig_NSLocale_currentLocale ? orig_NSLocale_currentLocale(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"NSLocale.currentLocale", value, nil);
    return value;
}

static id (*orig_NSLocale_autoupdatingCurrentLocale)(id, SEL);
static id rep_NSLocale_autoupdatingCurrentLocale(id self, SEL _cmd) {
    id value = orig_NSLocale_autoupdatingCurrentLocale ? orig_NSLocale_autoupdatingCurrentLocale(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"NSLocale.autoupdatingCurrentLocale", value, nil);
    return value;
}

static id (*orig_NSLocale_preferredLanguages)(id, SEL);
static id rep_NSLocale_preferredLanguages(id self, SEL _cmd) {
    id value = orig_NSLocale_preferredLanguages ? orig_NSLocale_preferredLanguages(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"NSLocale.preferredLanguages", value, nil);
    return value;
}

static id (*orig_NSTimeZone_localTimeZone)(id, SEL);
static id rep_NSTimeZone_localTimeZone(id self, SEL _cmd) {
    id value = orig_NSTimeZone_localTimeZone ? orig_NSTimeZone_localTimeZone(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"NSTimeZone.localTimeZone", value, nil);
    return value;
}

static id (*orig_NSTimeZone_systemTimeZone)(id, SEL);
static id rep_NSTimeZone_systemTimeZone(id self, SEL _cmd) {
    id value = orig_NSTimeZone_systemTimeZone ? orig_NSTimeZone_systemTimeZone(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"NSTimeZone.systemTimeZone", value, nil);
    return value;
}

static id (*orig_NSTimeZone_defaultTimeZone)(id, SEL);
static id rep_NSTimeZone_defaultTimeZone(id self, SEL _cmd) {
    id value = orig_NSTimeZone_defaultTimeZone ? orig_NSTimeZone_defaultTimeZone(self, _cmd) : nil;
    VPEmitDeviceReadOnce(@"NSTimeZone.defaultTimeZone", value, nil);
    return value;
}

static id (*orig_NSUserDefaults_objectForKey)(id, SEL, id);
static id rep_NSUserDefaults_objectForKey(id self, SEL _cmd, id key) {
    id value = orig_NSUserDefaults_objectForKey ? orig_NSUserDefaults_objectForKey(self, _cmd, key) : nil;
    if ([key isKindOfClass:NSString.class]) {
        NSString *k = (NSString *)key;
        if ([k isEqualToString:@"AppleLanguages"] || [k isEqualToString:@"AppleLocale"]) {
            VPEmitDeviceReadOnce([NSString stringWithFormat:@"NSUserDefaults.%@", k], value, nil);
        }
    }
    return value;
}

static CFTypeRef (*orig_MGCopyAnswer)(CFStringRef key);
static CFTypeRef rep_MGCopyAnswer(CFStringRef key) {
    CFTypeRef result = orig_MGCopyAnswer ? orig_MGCopyAnswer(key) : NULL;
    NSString *keyString = key ? (__bridge NSString *)key : @"<null>";
    id value = result ? CFBridgingRelease(CFRetain(result)) : nil;
    VPEmitDeviceReadOnce([NSString stringWithFormat:@"MGCopyAnswer:%@", keyString], value, nil);
    return result;
}

static void VPHookObjectiveC(void) {
    Class UIDeviceClass = NSClassFromString(@"UIDevice");
    VPHookInstanceMethod(UIDeviceClass, @selector(name), (IMP)rep_UIDevice_name, (IMP *)&orig_UIDevice_name);
    VPHookInstanceMethod(UIDeviceClass, @selector(model), (IMP)rep_UIDevice_model, (IMP *)&orig_UIDevice_model);
    VPHookInstanceMethod(UIDeviceClass, @selector(localizedModel), (IMP)rep_UIDevice_localizedModel, (IMP *)&orig_UIDevice_localizedModel);
    VPHookInstanceMethod(UIDeviceClass, @selector(systemName), (IMP)rep_UIDevice_systemName, (IMP *)&orig_UIDevice_systemName);
    VPHookInstanceMethod(UIDeviceClass, @selector(systemVersion), (IMP)rep_UIDevice_systemVersion, (IMP *)&orig_UIDevice_systemVersion);
    VPHookInstanceMethod(UIDeviceClass, @selector(identifierForVendor), (IMP)rep_UIDevice_identifierForVendor, (IMP *)&orig_UIDevice_identifierForVendor);

    Class IGScopedNetworkerClass = NSClassFromString(@"IGScopedNetworker");
    VPHookInstanceMethod(IGScopedNetworkerClass, @selector(routingHeadersWithRequest:), (IMP)rep_IGScopedNetworker_routingHeadersWithRequest, (IMP *)&orig_IGScopedNetworker_routingHeadersWithRequest);
    VPHookInstanceMethod(IGScopedNetworkerClass, @selector(APIHeadersAsCookies), (IMP)rep_IGScopedNetworker_APIHeadersAsCookies, (IMP *)&orig_IGScopedNetworker_APIHeadersAsCookies);

    Class IGUserAuthHeaderManagerClass = NSClassFromString(@"IGUserAuthHeaderManager");
    VPHookInstanceMethod(IGUserAuthHeaderManagerClass, @selector(authHeader), (IMP)rep_IGUserAuthHeaderManager_authHeader, (IMP *)&orig_IGUserAuthHeaderManager_authHeader);
    VPHookInstanceMethod(IGUserAuthHeaderManagerClass, @selector(loggingClaimHeader), (IMP)rep_IGUserAuthHeaderManager_loggingClaimHeader, (IMP *)&orig_IGUserAuthHeaderManager_loggingClaimHeader);

    Class IGDeviceHeaderClass = NSClassFromString(@"IGDeviceHeader");
    VPHookInstanceMethod(IGDeviceHeaderClass, @selector(header), (IMP)rep_IGDeviceHeader_header, (IMP *)&orig_IGDeviceHeader_header);
    VPHookInstanceMethod(IGDeviceHeaderClass, @selector(deviceHeader), (IMP)rep_IGDeviceHeader_deviceHeader, (IMP *)&orig_IGDeviceHeader_deviceHeader);
    VPHookInstanceMethod(IGDeviceHeaderClass, @selector(setHeader:), (IMP)rep_IGDeviceHeader_setHeader, (IMP *)&orig_IGDeviceHeader_setHeader);

    Class FBFamilySharedUserDefaultsLightImplClass = NSClassFromString(@"FBFamilySharedUserDefaultsLightImpl");
    VPHookInstanceMethod(FBFamilySharedUserDefaultsLightImplClass, @selector(familyDeviceId), (IMP)rep_FBFamilySharedUserDefaultsLightImpl_familyDeviceId, (IMP *)&orig_FBFamilySharedUserDefaultsLightImpl_familyDeviceId);

    Class IGUserAgentClass = VPResolveClass(@[
        @"IGUserAgent",
        @"_TtC11IGUserAgent11IGUserAgent"
    ]);
    VPHookInstanceMethod(IGUserAgentClass, @selector(commonHeaders), (IMP)rep_IGUserAgent_commonHeaders, (IMP *)&orig_IGUserAgent_commonHeaders);
    VPHookInstanceMethod(IGUserAgentClass, @selector(APIRequestString), (IMP)rep_IGUserAgent_APIRequestString, (IMP *)&orig_IGUserAgent_APIRequestString);
    VPHookClassMethod(IGUserAgentClass, @selector(staticAPIRequestString), (IMP)rep_IGUserAgent_staticAPIRequestString, (IMP *)&orig_IGUserAgent_staticAPIRequestString);

    Class FOATokenRegistrationKitClass = VPResolveClass(@[
        @"FOATokenRegistrationKit",
        @"_TtC23FOATokenRegistrationKit23FOATokenRegistrationKit"
    ]);
    VPHookClassMethod(FOATokenRegistrationKitClass, @selector(getDeviceId), (IMP)rep_FOATokenRegistrationKit_getDeviceId, (IMP *)&orig_FOATokenRegistrationKit_getDeviceId);

    // The broad Foundation / NSURLSession / NSJSONSerialization hooks were
    // useful for discovery but destabilized Instagram's background networking
    // stack (Tigon + URLSession worker threads) on this build. Keep the audit
    // tweak on the app's own stable providers only.

    dlopen("/System/Library/Frameworks/AdSupport.framework/AdSupport", RTLD_NOW | RTLD_GLOBAL);
    Class ASIdentifierManager = NSClassFromString(@"ASIdentifierManager");
    if (ASIdentifierManager) {
        VPHookInstanceMethod(ASIdentifierManager, @selector(advertisingIdentifier), (IMP)rep_AS_advertisingIdentifier, (IMP *)&orig_AS_advertisingIdentifier);
        VPHookInstanceMethod(ASIdentifierManager, @selector(isAdvertisingTrackingEnabled), (IMP)rep_AS_isAdvertisingTrackingEnabled, (IMP *)&orig_AS_isAdvertisingTrackingEnabled);
    }

    dlopen("/System/Library/Frameworks/AppTrackingTransparency.framework/AppTrackingTransparency", RTLD_NOW | RTLD_GLOBAL);
    Class ATTrackingManager = NSClassFromString(@"ATTrackingManager");
    if (ATTrackingManager) {
        VPHookClassMethod(ATTrackingManager, @selector(trackingAuthorizationStatus), (IMP)rep_ATT_trackingAuthorizationStatus, (IMP *)&orig_ATT_trackingAuthorizationStatus);
    }

    VPHookClassMethod(NSLocale.class, @selector(currentLocale), (IMP)rep_NSLocale_currentLocale, (IMP *)&orig_NSLocale_currentLocale);
    VPHookClassMethod(NSLocale.class, @selector(autoupdatingCurrentLocale), (IMP)rep_NSLocale_autoupdatingCurrentLocale, (IMP *)&orig_NSLocale_autoupdatingCurrentLocale);
    VPHookClassMethod(NSLocale.class, @selector(preferredLanguages), (IMP)rep_NSLocale_preferredLanguages, (IMP *)&orig_NSLocale_preferredLanguages);

    VPHookClassMethod(NSTimeZone.class, @selector(localTimeZone), (IMP)rep_NSTimeZone_localTimeZone, (IMP *)&orig_NSTimeZone_localTimeZone);
    VPHookClassMethod(NSTimeZone.class, @selector(systemTimeZone), (IMP)rep_NSTimeZone_systemTimeZone, (IMP *)&orig_NSTimeZone_systemTimeZone);
    VPHookClassMethod(NSTimeZone.class, @selector(defaultTimeZone), (IMP)rep_NSTimeZone_defaultTimeZone, (IMP *)&orig_NSTimeZone_defaultTimeZone);

    VPHookInstanceMethod(NSUserDefaults.class, @selector(objectForKey:), (IMP)rep_NSUserDefaults_objectForKey, (IMP *)&orig_NSUserDefaults_objectForKey);
}

static void VPHookMobileGestalt(void) {
    void *substrate = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_NOW | RTLD_GLOBAL);
    if (!substrate) substrate = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW | RTLD_GLOBAL);
    MSHookFunctionType hook = substrate ? (MSHookFunctionType)dlsym(substrate, "MSHookFunction") : NULL;
    if (!hook) return;

    void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW | RTLD_GLOBAL);
    void *sym = mg ? dlsym(mg, "MGCopyAnswer") : dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (sym) hook(sym, (void *)rep_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
}

__attribute__((constructor))
static void InstagramAuditTweakInit(void) {
    @autoreleasepool {
        if (!VPShouldInit()) return;
        VPLogLock = [NSLock new];
        VPWriteAccountStateFile();
        VPHookObjectiveC();
        VPHookMobileGestalt();
        VPScheduleStaticFieldProbe();
    }
}
