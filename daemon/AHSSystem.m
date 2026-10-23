#import "AHSSystem.h"
#import "AHSLog.h"
#import "../shared/SCCompat.h"
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef void *AHSWiFiManagerRef;

// MISManager states, as reported in the com.apple.MobileInternetSharing store key.
static const int kMISStateOn = 1023;
static const int kMISStateOff = 1022;

static NSString *const kLinkKey = @"State:/Network/Interface/en0/Link";
static NSString *const kIPv4Key = @"State:/Network/Interface/en0/IPv4";
static NSString *const kIPv6Key = @"State:/Network/Interface/en0/IPv6";
static NSString *const kAirPortKey = @"State:/Network/Interface/en0/AirPort";
static NSString *const kMISKey = @"com.apple.MobileInternetSharing";

@implementation AHSSystem {
    SCDynamicStoreRef _store;
    AHSWiFiManagerRef _wifi;
    int (*_wifiGetPower)(AHSWiFiManagerRef);
    void (*_wifiSetPower)(AHSWiFiManagerRef, bool);
    int (*_wifiGetDiscovery)(AHSWiFiManagerRef);
    id _misManager;
    id _wfClient;
    CFTypeRef (*_psCopyInfo)(void);
    CFArrayRef (*_psCopyList)(CFTypeRef);
    CFDictionaryRef (*_psGetDescription)(CFTypeRef, CFTypeRef);
    int _powerToken;
    int _lowPowerToken;
}

static void AHSStoreChanged(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
    AHSSystem *system = (__bridge AHSSystem *)info;
    [system reload];
    if (system.changeHandler) system.changeHandler();
}

- (BOOL)start {
    dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/WiFiKit.framework/WiFiKit", RTLD_LAZY);
    dlopen("/System/Library/PreferenceBundles/WirelessModemSettings.bundle/WirelessModemSettings", RTLD_LAZY);

    AHSWiFiManagerRef (*wifiCreate)(CFAllocatorRef, int) = dlsym(RTLD_DEFAULT, "WiFiManagerClientCreate");
    _wifiGetPower = dlsym(RTLD_DEFAULT, "WiFiManagerClientGetPower");
    _wifiSetPower = dlsym(RTLD_DEFAULT, "WiFiManagerClientSetPower");
    _wifiGetDiscovery = dlsym(RTLD_DEFAULT, "WiFiManagerClientGetMISDiscoveryState");
    Class misClass = objc_getClass("MISManager");
    Class wfClass = objc_getClass("WFClient");
    if (!wifiCreate || !_wifiGetPower || !_wifiSetPower || !_wifiGetDiscovery || !misClass || !wfClass) {
        AHSLog(@"系统接口缺失: create=%d power=%d setPower=%d discovery=%d MISManager=%d WFClient=%d",
               !!wifiCreate, !!_wifiGetPower, !!_wifiSetPower, !!_wifiGetDiscovery, !!misClass, !!wfClass);
        return NO;
    }
    _wifi = wifiCreate(kCFAllocatorDefault, 0);
    _misManager = ((id (*)(Class, SEL))objc_msgSend)(misClass, NSSelectorFromString(@"sharedManager"));
    _wfClient = ((id (*)(Class, SEL))objc_msgSend)(wfClass, NSSelectorFromString(@"sharedInstance"));
    if (!_wifi || !_misManager || !_wfClient) {
        AHSLog(@"系统接口初始化失败: wifi=%p mis=%@ wf=%@", _wifi, _misManager, _wfClient);
        return NO;
    }

    SCDynamicStoreContext context = { 0, (__bridge void *)self, NULL, NULL, NULL };
    _store = AHSStoreCreate(NULL, CFSTR("autohotspotd"), AHSStoreChanged, &context);
    NSArray *keys = @[ kLinkKey, kIPv4Key, kIPv6Key, kAirPortKey, kMISKey ];
    if (!_store || !AHSStoreSetNotificationKeys(_store, (__bridge CFArrayRef)keys, NULL) ||
        !AHSStoreSetDispatchQueue(_store, dispatch_get_main_queue())) {
        AHSLog(@"无法订阅网络状态变化");
        return NO;
    }
    [self reload];

    // IOPowerSources has no iOS SDK header.
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    _psCopyInfo = dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesInfo");
    _psCopyList = dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesList");
    _psGetDescription = dlsym(RTLD_DEFAULT, "IOPSGetPowerSourceDescription");
    __weak AHSSystem *weakSelf = self;
    void (^powerChanged)(int) = ^(int token) {
        AHSSystem *system = weakSelf;
        if (!system) return;
        [system reloadPower];
        if (system.changeHandler) system.changeHandler();
    };
    notify_register_dispatch("com.apple.system.powersources", &_powerToken, dispatch_get_main_queue(), powerChanged);
    notify_register_dispatch("com.apple.system.lowpowermode", &_lowPowerToken, dispatch_get_main_queue(), powerChanged);
    [self reloadPower];
    return YES;
}

- (void)reloadPower {
    _batteryLevel = -1;
    _externalPower = NO;
    _lowPowerMode = [NSProcessInfo processInfo].lowPowerModeEnabled;
    if (!_psCopyInfo || !_psCopyList || !_psGetDescription) return;

    CFTypeRef info = _psCopyInfo();
    if (!info) return;
    NSArray *sources = CFBridgingRelease(_psCopyList(info));
    for (id source in sources) {
        NSDictionary *description = (__bridge NSDictionary *)_psGetDescription(info, (__bridge CFTypeRef)source);
        NSInteger current = [description[@"Current Capacity"] integerValue];
        NSInteger max = [description[@"Max Capacity"] integerValue];
        if (max <= 0) continue;
        _batteryLevel = current * 100 / max;
        _externalPower = [description[@"Power Source State"] isEqual:@"AC Power"] || [description[@"Is Charging"] boolValue];
        break;
    }
    CFRelease(info);
}

- (NSDictionary *)valueForStoreKey:(NSString *)key {
    id value = CFBridgingRelease(AHSStoreCopyValue(_store, (__bridge CFStringRef)key));
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

// 169.254/16 is what iOS self-assigns when DHCP fails; that is not a usable Wi-Fi.
static BOOL AHSHasUsableIPv4(NSDictionary *ipv4) {
    for (NSString *address in ipv4[@"Addresses"]) {
        if ([address isKindOfClass:[NSString class]] && ![address hasPrefix:@"169.254."]) return YES;
    }
    return NO;
}

static BOOL AHSHasRoutableIPv6(NSDictionary *ipv6) {
    for (NSString *address in ipv6[@"Addresses"]) {
        if ([address isKindOfClass:[NSString class]] && ![address.lowercaseString hasPrefix:@"fe80"]) return YES;
    }
    return NO;
}

- (void)reload {
    NSDictionary *link = [self valueForStoreKey:kLinkKey];
    NSDictionary *ipv4 = [self valueForStoreKey:kIPv4Key];
    NSDictionary *ipv6 = [self valueForStoreKey:kIPv6Key];
    NSDictionary *mis = [self valueForStoreKey:kMISKey];
    NSDictionary *airport = [self valueForStoreKey:kAirPortKey];
    BOOL active = [link[@"Active"] boolValue];
    _wifiConnected = active && (AHSHasUsableIPv4(ipv4) || AHSHasRoutableIPv6(ipv6));
    _wifiDetail = [NSString stringWithFormat:@"link=%d ipv4=%@ ipv6=%@ ssid=%@", active,
                   [ipv4[@"Addresses"] componentsJoinedByString:@","] ?: @"-",
                   [ipv6[@"Addresses"] componentsJoinedByString:@","] ?: @"-", airport[@"SSID_STR"] ?: @"-"];
    _hotspotOn = [mis[@"State"] intValue] == kMISStateOn;
    _hostCount = [mis[@"Hosts"][@"Current"] integerValue];
}

- (BOOL)wifiPowered {
    return _wifiGetPower(_wifi) != 0;
}

- (BOOL)discoveryEnabled {
    return _wifiGetDiscovery(_wifi) != 0;
}

- (NSString *)hotspotDebugState {
    int state = 0, reason = 0;
    ((void (*)(id, SEL, int *, int *))objc_msgSend)(_misManager, NSSelectorFromString(@"getState:andReason:"), &state, &reason);
    return [NSString stringWithFormat:@"state=%d reason=%d discovery=%d hosts=%ld", state, reason, self.discoveryEnabled, (long)_hostCount];
}

- (void)setWiFiPowered:(BOOL)powered {
    _wifiSetPower(_wifi, powered);
}

- (void)setHotspotEnabled:(BOOL)enabled {
    if (enabled) {
        ((void (*)(id, SEL, int))objc_msgSend)(_misManager, NSSelectorFromString(@"setState:"), kMISStateOn);
        // Discovery only sticks once misd reports the hotspot as running.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.hotspotOn) [self setDiscoveryEnabled:YES];
        });
    } else {
        [self setDiscoveryEnabled:NO];
        ((void (*)(id, SEL, int))objc_msgSend)(_misManager, NSSelectorFromString(@"setState:"), kMISStateOff);
    }
}

- (void)setDiscoveryEnabled:(BOOL)enabled {
    ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(_wfClient, NSSelectorFromString(@"setMISDiscoveryState:immediateDisable:"), enabled, !enabled);
}
@end
