// Throwaway spike: answers "can we find the hotspot API" and "can we see the Air over BLE".
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "../shared/SCCompat.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

static void dumpClass(const char *name) {
    Class cls = objc_getClass(name);
    if (!cls) { printf("%s: not loaded\n", name); return; }
    printf("%s in %s\n", name, class_getImageName(cls));
    for (int meta = 1; meta >= 0; meta--) {
        Class c = meta ? object_getClass((id)cls) : cls;
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            printf("  %c%s  %s\n", meta ? '+' : '-', sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
        }
        free(ms);
    }
    unsigned int pn = 0;
    objc_property_t *ps = class_copyPropertyList(cls, &pn);
    for (unsigned int i = 0; i < pn; i++) printf("  @property %s  %s\n", property_getName(ps[i]), property_getAttributes(ps[i]));
    free(ps);
}

static void cmdClasses(void) {
    const char *libs[] = {
        "/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
        "/System/Library/PrivateFrameworks/WiFiKit.framework/WiFiKit",
        "/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi",
        "/System/Library/PrivateFrameworks/Rapport.framework/Rapport",
        "/System/Library/PrivateFrameworks/Sharing.framework/Sharing",
        "/System/Library/PreferenceBundles/WirelessModemSettings.bundle/WirelessModemSettings",
        NULL,
    };
    for (int i = 0; libs[i]; i++) {
        void *h = dlopen(libs[i], RTLD_LAZY);
        printf("dlopen %s -> %s\n", libs[i], h ? "ok" : dlerror());
    }
    const char *classes[] = { "MISManager", "WirelessModemController", "RPCompanionLinkClient", "RPCompanionLinkDevice", "SFDeviceDiscovery", NULL };
    for (int i = 0; classes[i]; i++) dumpClass(classes[i]);
}

static void cmdStore(void) {
    SCDynamicStoreRef store = AHSStoreCreate(NULL, CFSTR("ahsprobe"), NULL, NULL);
    NSArray *keys = CFBridgingRelease(AHSStoreCopyKeyList(store, CFSTR(".*")));
    for (NSString *k in [keys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([k rangeOfString:@"Interface/en0" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [k rangeOfString:@"Global" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [k rangeOfString:@"Sharing" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [k rangeOfString:@"AirPort" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            id v = CFBridgingRelease(AHSStoreCopyValue(store, (__bridge CFStringRef)k));
            printf("== %s\n%s\n", k.UTF8String, [[v description] UTF8String]);
        }
    }
    printf("(%lu keys total)\n", (unsigned long)keys.count);
    CFRelease(store);
}

@interface Seen : NSObject
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *mfr;
@property (nonatomic) NSInteger count, maxRSSI, lastRSSI;
@property (nonatomic, copy) NSString *model;
@end
@implementation Seen @end

@interface Scanner : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, Seen *> *seen;
@property (nonatomic) BOOL readModels;
@property (nonatomic) NSInteger minRSSI;
@end

@implementation Scanner
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    printf("central state=%ld\n", (long)central.state);
    if (central.state == CBManagerStatePoweredOn) {
        NSMutableDictionary *opts = [@{ CBCentralManagerScanOptionAllowDuplicatesKey: @YES } mutableCopy];
        NSString * __unsafe_unretained *k = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "CBCentralManagerScanOptionIsPrivilegedDaemonKey");
        printf("scan privileged key: %s\n", k ? (*k).UTF8String : "missing");
        if (k && getenv("AHS_PRIV")) opts[*k] = @YES;
        [central scanForPeripheralsWithServices:nil options:opts];
    }
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)p advertisementData:(NSDictionary *)ad RSSI:(NSNumber *)RSSI {
    NSData *m = ad[CBAdvertisementDataManufacturerDataKey];
    Seen *s = self.seen[p.identifier];
    if (!s) { s = [Seen new]; s.peripheral = p; s.maxRSSI = -999; self.seen[p.identifier] = s; }
    s.count++;
    s.lastRSSI = RSSI.integerValue;
    if (RSSI.integerValue < 127 && RSSI.integerValue > s.maxRSSI) s.maxRSSI = RSSI.integerValue;
    if (p.name.length) s.name = p.name;
    else if (ad[CBAdvertisementDataLocalNameKey]) s.name = ad[CBAdvertisementDataLocalNameKey];
    if (m.length) {
        NSMutableString *hex = [NSMutableString string];
        const uint8_t *b = m.bytes;
        for (NSUInteger i = 0; i < m.length; i++) [hex appendFormat:@"%02x", b[i]];
        s.mfr = hex;
    }
}
- (void)readModelsNow {
    for (Seen *s in self.seen.allValues) {
        if ([s.mfr hasPrefix:@"4c00"] && s.maxRSSI >= self.minRSSI) {
            s.peripheral.delegate = self;
            [self.central connectPeripheral:s.peripheral options:nil];
        }
    }
}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)p {
    [p discoverServices:@[ [CBUUID UUIDWithString:@"180A"] ]];
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)error {
    printf("connect fail %s: %s\n", p.identifier.UUIDString.UTF8String, error.localizedDescription.UTF8String);
}
- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(NSError *)error {
    for (CBService *svc in p.services) [p discoverCharacteristics:nil forService:svc];
}
- (void)peripheral:(CBPeripheral *)p didDiscoverCharacteristicsForService:(CBService *)svc error:(NSError *)error {
    for (CBCharacteristic *c in svc.characteristics) [p readValueForCharacteristic:c];
}
- (void)peripheral:(CBPeripheral *)p didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {
    NSString *v = c.value ? [[NSString alloc] initWithData:c.value encoding:NSUTF8StringEncoding] : nil;
    printf("  %s char %s = %s\n", p.identifier.UUIDString.UTF8String, c.UUID.UUIDString.UTF8String, v.UTF8String ?: "(nil)");
    if ([c.UUID isEqual:[CBUUID UUIDWithString:@"2A24"]]) self.seen[p.identifier].model = v;
}
- (void)report {
    NSArray *all = [self.seen.allValues sortedArrayUsingComparator:^NSComparisonResult(Seen *a, Seen *b) {
        return a.maxRSSI > b.maxRSSI ? NSOrderedAscending : NSOrderedDescending;
    }];
    printf("total peripherals seen: %lu\n", (unsigned long)all.count);
    for (Seen *s in all) {
        if (s.maxRSSI < self.minRSSI) continue;
        printf("%s rssi max=%ld last=%ld n=%ld name=%s model=%s mfr=%s\n", s.peripheral.identifier.UUIDString.UTF8String,
               (long)s.maxRSSI, (long)s.lastRSSI, (long)s.count, s.name.UTF8String ?: "-", s.model.UTF8String ?: "-", s.mfr.UTF8String ?: "-");
    }
}
@end

static void cmdScan(double seconds, BOOL models, NSInteger minRSSI) {
    Scanner *sc = [Scanner new];
    sc.seen = [NSMutableDictionary dictionary];
    sc.readModels = models;
    sc.minRSSI = minRSSI;
    NSMutableDictionary *initOpts = [NSMutableDictionary dictionary];
    NSString * __unsafe_unretained *k = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "CBManagerIsPrivilegedDaemonKey");
    printf("init privileged key: %s\n", k ? (*k).UTF8String : "missing");
    if (k && getenv("AHS_PRIV")) initOpts[*k] = @YES;
    sc.central = [[CBCentralManager alloc] initWithDelegate:sc queue:nil options:initOpts];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    if (models) {
        [sc.central stopScan];
        [sc readModelsNow];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:8]];
    }
    [sc report];
}

static void cmdRapport(double seconds) {
    dlopen("/System/Library/PrivateFrameworks/Rapport.framework/Rapport", RTLD_LAZY);
    Class cls = objc_getClass("RPCompanionLinkClient");
    if (!cls) { printf("no RPCompanionLinkClient\n"); return; }
    id client = [cls new];
    void (^found)(id) = ^(id d) { printf("found: %s\n", [[d description] UTF8String]); };
    if ([client respondsToSelector:@selector(setDeviceFoundHandler:)]) ((void (*)(id, SEL, id))objc_msgSend)(client, @selector(setDeviceFoundHandler:), found);
    ((void (*)(id, SEL, id))objc_msgSend)(client, NSSelectorFromString(@"activateWithCompletion:"), ^(NSError *e) {
        printf("activate: %s\n", e ? e.description.UTF8String : "ok");
    });
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    id devices = ((id (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"activeDevices"));
    printf("activeDevices:\n%s\n", [[devices description] UTF8String]);
}

static void printMIS(id mgr) {
    int state = 0, reason = 0;
    ((void (*)(id, SEL, int *, int *))objc_msgSend)(mgr, NSSelectorFromString(@"getState:andReason:"), &state, &reason);
    SCDynamicStoreRef store = AHSStoreCreate(NULL, CFSTR("ahsprobe"), NULL, NULL);
    NSDictionary *v = CFBridgingRelease(AHSStoreCopyValue(store, CFSTR("com.apple.MobileInternetSharing")));
    CFRelease(store);
    printf("MISManager state=%d reason=%d | store State=%s Hosts.Current=%s\n", state, reason,
           [[v[@"State"] description] UTF8String], [[v[@"Hosts"][@"Current"] description] UTF8String]);
}

static void cmdHotspot(const char *arg) {
    dlopen("/System/Library/PreferenceBundles/WirelessModemSettings.bundle/WirelessModemSettings", RTLD_LAZY);
    id mgr = ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("MISManager"), NSSelectorFromString(@"sharedManager"));
    printMIS(mgr);
    if (!arg) return;
    int target = strcmp(arg, "on") == 0 ? 1023 : 1022;
    ((void (*)(id, SEL, int))objc_msgSend)(mgr, NSSelectorFromString(@"setState:"), target);
    for (int i = 1; i <= 4; i++) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        printf("t+%.1fs ", i * 1.5);
        printMIS(mgr);
    }
}

static void cmdGrep(const char *pattern) {
    const char *libs[] = {
        "/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
        "/System/Library/PrivateFrameworks/WiFiKit.framework/WiFiKit",
        "/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi",
        "/System/Library/PrivateFrameworks/WiFiPolicy.framework/WiFiPolicy",
        "/System/Library/PrivateFrameworks/Sharing.framework/Sharing",
        "/System/Library/PreferenceBundles/WirelessModemSettings.bundle/WirelessModemSettings",
        NULL,
    };
    NSString *pat = @(pattern);
    for (int i = 0; libs[i]; i++) {
        dlopen(libs[i], RTLD_LAZY);
        unsigned int cn = 0;
        const char **names = objc_copyClassNamesForImage(libs[i], &cn);
        for (unsigned int j = 0; j < cn; j++) {
            Class cls = objc_getClass(names[j]);
            for (int meta = 1; meta >= 0; meta--) {
                Class c = meta ? object_getClass((id)cls) : cls;
                unsigned int n = 0;
                Method *ms = class_copyMethodList(c, &n);
                for (unsigned int k = 0; k < n; k++) {
                    NSString *sel = @(sel_getName(method_getName(ms[k])));
                    if ([sel rangeOfString:pat options:NSCaseInsensitiveSearch].location != NSNotFound)
                        printf("%s %c[%s %s] %s\n", strrchr(libs[i], '/') + 1, meta ? '+' : '-', names[j], sel.UTF8String, method_getTypeEncoding(ms[k]));
                }
                free(ms);
            }
        }
        free(names);
    }
    const char *syms[] = {
        "WiFiManagerClientCreate", "WiFiManagerClientGetPower", "WiFiManagerClientSetPower",
        "WiFiManagerClientCopyDevices", "WiFiDeviceClientCopyCurrentNetwork",
        "WiFiManagerClientSetMISDiscoveryState", "WiFiManagerClientSetMISDiscoveryStateExt",
        "WiFiManagerClientGetMISDiscoveryState", "WiFiManagerClientSetMISState", "WiFiManagerClientGetMISState",
        "WiFiManagerClientSetMisPassword", "WiFiManagerClientCopyMisPassword", NULL,
    };
    for (int i = 0; syms[i]; i++) printf("sym %s: %s\n", syms[i], dlsym(RTLD_DEFAULT, syms[i]) ? "yes" : "no");
}

static void cmdDisc(const char *arg) {
    dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/WiFiKit.framework/WiFiKit", RTLD_LAZY);
    void *(*create)(CFAllocatorRef, int) = dlsym(RTLD_DEFAULT, "WiFiManagerClientCreate");
    int (*getDisc)(void *) = dlsym(RTLD_DEFAULT, "WiFiManagerClientGetMISDiscoveryState");
    int (*getMIS)(void *) = dlsym(RTLD_DEFAULT, "WiFiManagerClientGetMISState");
    int (*getPower)(void *) = dlsym(RTLD_DEFAULT, "WiFiManagerClientGetPower");
    void *mgr = create(kCFAllocatorDefault, 0);
    printf("C: power=%d misState=%d discovery=%d\n", getPower(mgr), getMIS(mgr), getDisc(mgr));
    id wf = ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("WFClient"), NSSelectorFromString(@"sharedInstance"));
    ((void (*)(id, SEL, id))objc_msgSend)(wf, NSSelectorFromString(@"asyncMISDiscoveryState:"), ^(long v) { printf("WFClient discovery=%ld\n", v); });
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    if (!arg) return;
    BOOL on = strcmp(arg, "on") == 0;
    ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(wf, NSSelectorFromString(@"setMISDiscoveryState:immediateDisable:"), on, !on);
    for (int i = 1; i <= 3; i++) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        printf("t+%.1fs C: misState=%d discovery=%d\n", i * 1.5, getMIS(mgr), getDisc(mgr));
    }
}

static void cmdWiFiPower(const char *arg) {
    dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    void *(*create)(CFAllocatorRef, int) = dlsym(RTLD_DEFAULT, "WiFiManagerClientCreate");
    int (*getPower)(void *) = dlsym(RTLD_DEFAULT, "WiFiManagerClientGetPower");
    void (*setPower)(void *, bool) = dlsym(RTLD_DEFAULT, "WiFiManagerClientSetPower");
    void *mgr = create(kCFAllocatorDefault, 0);
    if (arg) {
        setPower(mgr, strcmp(arg, "on") == 0);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
    }
    printf("wifi power=%d\n", getPower(mgr));
}

// Mimics the Settings pane: write as user mobile, then poke the daemon.
static void cmdSetPref(const char *key, const char *value) {
    CFStringRef domain = CFSTR("com.xcode.autohotspot");
    NSString *k = @(key);
    id v = value ? @(atoi(value)) : nil;
    CFPreferencesSetValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v, domain, CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPreferencesSynchronize(domain, CFSTR("mobile"), kCFPreferencesAnyHost);
    notify_post("com.xcode.autohotspot/prefs-changed");
    printf("set %s = %s\n", key, value ?: "(removed)");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        NSString *cmd = argc > 1 ? @(argv[1]) : @"classes";
        if ([cmd isEqualToString:@"classes"]) cmdClasses();
        else if ([cmd isEqualToString:@"store"]) cmdStore();
        else if ([cmd isEqualToString:@"scan"]) cmdScan(argc > 2 ? atof(argv[2]) : 10, NO, argc > 3 ? atoi(argv[3]) : -90);
        else if ([cmd isEqualToString:@"models"]) cmdScan(argc > 2 ? atof(argv[2]) : 10, YES, argc > 3 ? atoi(argv[3]) : -70);
        else if ([cmd isEqualToString:@"setpref"] && argc > 2) cmdSetPref(argv[2], argc > 3 ? argv[3] : NULL);
        else if ([cmd isEqualToString:@"post"] && argc > 2) printf("notify_post %s -> %u\n", argv[2], notify_post(argv[2]));
        else if ([cmd isEqualToString:@"wifipower"]) cmdWiFiPower(argc > 2 ? argv[2] : NULL);
        else if ([cmd isEqualToString:@"disc"]) cmdDisc(argc > 2 ? argv[2] : NULL);
        else if ([cmd isEqualToString:@"grep"]) cmdGrep(argc > 2 ? argv[2] : "MIS");
        else if ([cmd isEqualToString:@"hotspot"]) cmdHotspot(argc > 2 ? argv[2] : NULL);
        else if ([cmd isEqualToString:@"rapport"]) cmdRapport(argc > 2 ? atof(argv[2]) : 10);
        else printf("usage: ahsprobe classes|store|scan [sec] [minRSSI]|models [sec] [minRSSI]|rapport [sec]\n");
    }
    return 0;
}
