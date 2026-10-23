#import "AHSController.h"
#import "AHSLog.h"
#import "AHSScanner.h"
#import "AHSSystem.h"
#import "../shared/AHSShared.h"
#import <notify.h>
#import <roothide.h>
#import <sys/stat.h>

static const NSTimeInterval kMinWaitingInterval = 60;
static const NSTimeInterval kScanWindow = 5;
// State mismatches this soon after our own toggle are misd catching up, not the user.
static const NSTimeInterval kActionSettle = 15;
static const NSTimeInterval kWiFiPowerSettle = 4;
static const NSTimeInterval kWiFiPowerRetry = 30;
static const NSTimeInterval kWaitingTick = 30;
// en0 flaps for a few seconds while the hotspot is up; only a lasting association counts.
static const NSTimeInterval kWiFiDebounce = 10;
static const NSUInteger kMaxRememberedIdentifiers = 4;
static NSString *const kMobilePrefsFile = @"/var/mobile/Library/Preferences/com.xcode.autohotspot.plist";

static NSTimeInterval AHSNow(void) {
    return [NSDate date].timeIntervalSince1970;
}

static void AHSAfter(NSTimeInterval seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

@implementation AHSController {
    AHSSystem *_system;
    AHSScanner *_scanner;
    NSString *_statePath;
    NSDateFormatter *_eventFormatter;

    // Settings
    BOOL _settingsLoaded;
    BOOL _enabled;
    NSInteger _rssiThreshold;
    NSTimeInterval _leaveDelay;
    NSTimeInterval _idleTimeout;
    NSTimeInterval _cooldown;
    NSString *_targetModel;
    NSTimeInterval _searchInterval;
    BOOL _autoWiFiPower;
    NSInteger _lowBatteryThreshold;
    BOOL _pauseInLowPowerMode;
    BOOL _scheduleEnabled;
    NSInteger _scheduleStart;
    NSInteger _scheduleEnd;
    NSInteger _scheduleWeekdays;

    // Persisted
    BOOL _ownsHotspot;
    BOOL _poweredWiFi;
    NSTimeInterval _cooldownUntil;
    NSMutableArray<NSString *> *_deviceIdentifiers;
    NSString *_deviceName;

    // Runtime
    AHSPhase _phase;
    BOOL _pendingOff;
    // "Open now" from Settings: skips detection, schedule and battery limits for one session.
    BOOL _manualOpenRequested;
    BOOL _manualSession;
    NSTimeInterval _lastSeen;
    NSInteger _lastRSSI;
    NSTimeInterval _onSince;
    NSTimeInterval _lastClientAt;
    NSTimeInterval _lastActionAt;
    NSTimeInterval _wifiPowerRequestedAt;
    BOOL _rawWiFiConnected;
    NSTimeInterval _wifiConnectedSince;
    BOOL _sightingLogged;
    NSTimeInterval _scanInterval;
    NSUInteger _scanGeneration;
    NSUInteger _tickGeneration;
    NSString *_lastEvent;
    NSString *_statusSignature;
    int _prefsToken;
    int _relearnToken;
    int _openNowToken;
    int _closeNowToken;
}

+ (void)releaseOwnedHotspot {
    AHSController *controller = [AHSController new];
    controller->_statePath = jbroot(@AHSStateFile);
    [controller loadState];
    if (!controller->_ownsHotspot) return;
    controller->_system = [AHSSystem new];
    if (![controller->_system start]) return;

    AHSLog(@"卸载：关闭本插件开的热点");
    [controller->_system setHotspotEnabled:NO];
    if (controller->_poweredWiFi && !controller->_system.wifiConnected) [controller->_system setWiFiPowered:NO];
    controller->_ownsHotspot = NO;
    controller->_poweredWiFi = NO;
    [controller saveState];
    // Let the XPC requests reach misd/wifid before the process exits.
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
}

- (BOOL)start {
    _statePath = jbroot(@AHSStateFile);
    _eventFormatter = [NSDateFormatter new];
    _eventFormatter.dateFormat = @"MM-dd HH:mm:ss";
    _phase = AHSPhaseStarting;
    [self loadState];

    _system = [AHSSystem new];
    if (![_system start]) return NO;
    _scanner = [AHSScanner new];
    [self reloadSettings];
    [self applyTargetToScanner];

    if (_ownsHotspot && !_system.hotspotOn) {
        AHSLog(@"上次开的热点已不在，清除记录");
        _ownsHotspot = NO;
    }

    __weak AHSController *weakSelf = self;
    _system.changeHandler = ^{ [weakSelf evaluate]; };
    _scanner.stateHandler = ^{ [weakSelf evaluate]; };
    _scanner.sightingHandler = ^(NSUUID *identifier, NSInteger rssi) { [weakSelf sawTargetWithRSSI:rssi]; };
    _scanner.learnedHandler = ^(NSUUID *identifier, NSString *name) { [weakSelf learnIdentifier:identifier name:name]; };
    dispatch_queue_t main = dispatch_get_main_queue();
    notify_register_dispatch(AHSPrefsChangedNotification, &_prefsToken, main, ^(int token) {
        [weakSelf settingsChanged];
    });
    notify_register_dispatch(AHSRelearnNotification, &_relearnToken, main, ^(int token) {
        [weakSelf forgetDevice];
    });
    notify_register_dispatch(AHSOpenNowNotification, &_openNowToken, main, ^(int token) {
        [weakSelf openNow];
    });
    notify_register_dispatch(AHSCloseNowNotification, &_closeNowToken, main, ^(int token) {
        [weakSelf closeNow];
    });

    AHSLog(@"初始: Wi‑Fi已连接=%d Wi‑Fi电源=%d 热点=%d 本插件开的=%d 电量=%ld%% 外接电源=%d 低电量模式=%d 已识别=%@ %@",
           _system.wifiConnected, _system.wifiPowered, _system.hotspotOn, _ownsHotspot, (long)_system.batteryLevel,
           _system.externalPower, _system.lowPowerMode, _deviceName ?: @"(无)", _deviceIdentifiers.firstObject ?: @"");
    [self evaluate];
    return YES;
}

- (void)shutdown {
    if (_ownsHotspot) [self turnOffHotspot:@"服务停止" cooldown:NO];
    [_scanner setScanning:NO];
    AHSLog(@"autohotspotd 退出");
}

#pragma mark - Settings and state

static NSInteger AHSInteger(NSDictionary *prefs, NSString *key, NSInteger fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static BOOL AHSBool(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

- (void)reloadSettings {
    CFPreferencesSynchronize(AHSPrefsDomain, CFSTR("mobile"), kCFPreferencesAnyHost);
    NSDictionary *prefs = CFBridgingRelease(CFPreferencesCopyMultiple(NULL, AHSPrefsDomain, CFSTR("mobile"), kCFPreferencesAnyHost));
    if (prefs.count == 0) prefs = [NSDictionary dictionaryWithContentsOfFile:kMobilePrefsFile];

    BOOL wasEnabled = _enabled;
    _enabled = AHSBool(prefs, AHSKeyEnabled, YES);
    // Switching the feature back on is the user's way to skip a cooldown.
    if (_settingsLoaded && !wasEnabled && _enabled && _cooldownUntil > 0) {
        AHSLog(@"重新启用，清除冷却");
        _cooldownUntil = 0;
        [self saveState];
    }
    _rssiThreshold = AHSInteger(prefs, AHSKeyRSSIThreshold, AHSDefaultRSSIThreshold);
    _leaveDelay = AHSInteger(prefs, AHSKeyLeaveDelay, AHSDefaultLeaveDelay);
    _idleTimeout = AHSInteger(prefs, AHSKeyIdleTimeout, AHSDefaultIdleTimeout);
    _cooldown = AHSInteger(prefs, AHSKeyCooldown, AHSDefaultCooldown);
    _searchInterval = MAX(AHSInteger(prefs, AHSKeyScanInterval, AHSDefaultScanInterval), kScanWindow + 1);
    _autoWiFiPower = AHSBool(prefs, AHSKeyAutoWiFiPower, YES);
    _lowBatteryThreshold = AHSInteger(prefs, AHSKeyLowBatteryThreshold, AHSDefaultLowBatteryThreshold);
    _pauseInLowPowerMode = AHSBool(prefs, AHSKeyPauseInLowPowerMode, NO);
    _scheduleEnabled = AHSBool(prefs, AHSKeyScheduleEnabled, NO);
    _scheduleStart = AHSInteger(prefs, AHSKeyScheduleStart, AHSDefaultScheduleStart);
    _scheduleEnd = AHSInteger(prefs, AHSKeyScheduleEnd, AHSDefaultScheduleEnd);
    _scheduleWeekdays = 0;
    for (NSInteger weekday = 1; weekday <= 7; weekday++) {
        NSString *key = [AHSKeyScheduleWeekdayPrefix stringByAppendingFormat:@"%ld", (long)weekday];
        if (AHSBool(prefs, key, YES)) _scheduleWeekdays |= 1 << weekday;
    }
    NSString *model = prefs[AHSKeyTargetModel];
    model = [model isKindOfClass:[NSString class]] ? [model stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : nil;
    _targetModel = model.length ? model : AHSDefaultTargetModel;
    _scanner.targetModel = _targetModel;
    _settingsLoaded = YES;

    AHSLog(@"设置: 启用=%d 阈值=%ld dBm 离开=%.0fs 空等=%.0fs 冷却=%.0fs 扫描间隔=%.0fs 自动开Wi‑Fi=%d 低电量=%ld%% 低电量模式暂停=%d 定时=%d %@-%@ %@ 型号=%@",
           _enabled, (long)_rssiThreshold, _leaveDelay, _idleTimeout, _cooldown, _searchInterval, _autoWiFiPower,
           (long)_lowBatteryThreshold, _pauseInLowPowerMode, _scheduleEnabled, AHSMinutesText(_scheduleStart),
           AHSMinutesText(_scheduleEnd), AHSWeekdaysSummary(_scheduleWeekdays), _targetModel);
}

- (void)settingsChanged {
    [self reloadSettings];
    // A new scan interval only takes effect when the cycle restarts.
    _scanInterval = 0;
    [self applyScanPolicy];
    [self evaluate];
}

- (void)loadState {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:_statePath];
    _ownsHotspot = [state[AHSStateOwnsHotspot] boolValue];
    _poweredWiFi = [state[AHSStatePoweredWiFi] boolValue];
    _cooldownUntil = [state[AHSStateCooldownUntil] doubleValue];
    NSArray *identifiers = state[AHSStateDeviceIdentifiers];
    _deviceIdentifiers = [identifiers isKindOfClass:[NSArray class]] ? [identifiers mutableCopy] : [NSMutableArray array];
    NSString *name = state[AHSStateDeviceName];
    _deviceName = [name isKindOfClass:[NSString class]] && name.length ? name : nil;
    _lastEvent = state[AHSStateLastEvent];
}

- (void)saveState {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[AHSStateOwnsHotspot] = @(_ownsHotspot);
    state[AHSStatePoweredWiFi] = @(_poweredWiFi);
    state[AHSStateCooldownUntil] = @(_cooldownUntil);
    state[AHSStateDeviceIdentifiers] = _deviceIdentifiers;
    if (_deviceName) state[AHSStateDeviceName] = _deviceName;
    state[AHSStatePhase] = @(_phase);
    state[AHSStateLastSeen] = @(_lastSeen);
    state[AHSStateLastRSSI] = @(_lastRSSI);
    state[AHSStateHostCount] = @(_system.hostCount);
    state[AHSStateBatteryLevel] = @(_system.batteryLevel);
    state[AHSStateCharging] = @(_system.externalPower);
    state[AHSStateUpdatedAt] = @(AHSNow());
    if (_lastEvent) state[AHSStateLastEvent] = _lastEvent;

    NSString *directory = _statePath.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                               attributes:@{ NSFilePosixPermissions: @0755 } error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    if (![data writeToFile:_statePath atomically:YES]) {
        AHSLog(@"无法写入状态文件 %@", _statePath);
        return;
    }
    chmod(_statePath.fileSystemRepresentation, 0644);
    notify_post(AHSStatusChangedNotification);
}

- (void)recordEvent:(NSString *)event {
    _lastEvent = [NSString stringWithFormat:@"%@ %@", [_eventFormatter stringFromDate:[NSDate date]], event];
}

#pragma mark - Target device

- (void)applyTargetToScanner {
    _scanner.targetIdentifiers = _deviceIdentifiers;
    _scanner.targetName = _deviceName;
}

- (void)learnIdentifier:(NSUUID *)identifier name:(NSString *)name {
    NSString *uuid = identifier.UUIDString;
    BOOL changed = NO;
    if (![_deviceIdentifiers containsObject:uuid]) {
        [_deviceIdentifiers insertObject:uuid atIndex:0];
        while (_deviceIdentifiers.count > kMaxRememberedIdentifiers) [_deviceIdentifiers removeLastObject];
        changed = YES;
    }
    if (name.length && ![name isEqualToString:_deviceName]) {
        _deviceName = name;
        changed = YES;
    }
    if (!changed) return;
    AHSLog(@"记住目标设备: %@ %@", _deviceName ?: @"(无名称)", uuid);
    [self applyTargetToScanner];
    [self recordEvent:[NSString stringWithFormat:@"识别到 %@", _deviceName ?: uuid]];
    [self saveState];
}

- (void)forgetDevice {
    [_deviceIdentifiers removeAllObjects];
    _deviceName = nil;
    _lastSeen = 0;
    [self applyTargetToScanner];
    AHSLog(@"已清除目标设备，重新识别");
    [self recordEvent:@"清除设备，重新识别"];
    [self saveState];
    [self evaluate];
}

- (void)sawTargetWithRSSI:(NSInteger)rssi {
    _lastRSSI = rssi;
    BOOL strong = rssi >= _rssiThreshold;
    if (!_sightingLogged) {
        _sightingLogged = YES;
        AHSLog(@"看到 Air: %ld dBm%@", (long)rssi, strong ? @"" : @" (低于阈值，忽略)");
    }
    if (!strong) return;
    _lastSeen = AHSNow();
    if (_phase == AHSPhaseSearching) [self evaluate];
}

#pragma mark - Manual control

- (void)openNow {
    if (!_enabled) {
        AHSLog(@"立即打开: 功能已关闭，忽略");
        [self recordEvent:@"功能已关闭，没有打开热点"];
    } else if (_rawWiFiConnected) {
        // The radio cannot host a hotspot while it is associated as a client.
        AHSLog(@"立即打开: 本机连着 Wi‑Fi，忽略");
        [self recordEvent:@"本机连着 Wi‑Fi，不能开热点"];
    } else if (_system.hotspotOn && !_ownsHotspot) {
        AHSLog(@"立即打开: 接管已经开着的热点");
        _ownsHotspot = YES;
        _manualSession = YES;
        _pendingOff = NO;
        _onSince = AHSNow();
        _lastActionAt = _onSince;
        [_system setDiscoveryEnabled:YES];
        [self recordEvent:@"接管已开的热点"];
    } else if (!_ownsHotspot) {
        AHSLog(@"立即打开: 收到请求");
        _cooldownUntil = 0;
        _manualOpenRequested = YES;
    }
    [self saveState];
    [self evaluate];
}

- (void)closeNow {
    if (_ownsHotspot) {
        [self turnOffHotspot:@"手动关闭" cooldown:YES];
    } else if (_system.hotspotOn) {
        AHSLog(@"立即关闭: 关闭手动打开的热点，冷却 %.0f 分钟", _cooldown / 60);
        [_system setHotspotEnabled:NO];
        _pendingOff = YES;
        _lastActionAt = AHSNow();
        _cooldownUntil = _lastActionAt + _cooldown;
        [self recordEvent:@"手动关闭热点"];
    } else {
        AHSLog(@"立即关闭: 热点本来就是关的，冷却 %.0f 分钟", _cooldown / 60);
        _cooldownUntil = AHSNow() + _cooldown;
        [self recordEvent:@"手动暂停"];
    }
    _manualOpenRequested = NO;
    [self saveState];
    [self evaluate];
}

#pragma mark - Decisions

- (BOOL)batteryPaused {
    if (_system.externalPower) return NO;
    if (_pauseInLowPowerMode && _system.lowPowerMode) return YES;
    return _lowBatteryThreshold > 0 && _system.batteryLevel >= 0 && _system.batteryLevel <= _lowBatteryThreshold;
}

- (BOOL)insideScheduleAt:(NSTimeInterval)now {
    if (!_scheduleEnabled) return YES;
    return AHSScheduleContains([NSDate dateWithTimeIntervalSince1970:now], _scheduleStart, _scheduleEnd, _scheduleWeekdays);
}

- (AHSPhase)phaseAt:(NSTimeInterval)now {
    if (!_enabled) return AHSPhaseDisabled;
    if (_wifiConnectedSince > 0 && now - _wifiConnectedSince >= kWiFiDebounce) return AHSPhaseOnWiFi;
    BOOL manual = _manualOpenRequested || (_manualSession && _ownsHotspot);
    if (!manual && [self batteryPaused]) return AHSPhaseLowBattery;
    if (!manual && ![self insideScheduleAt:now]) return AHSPhaseOutsideSchedule;
    if (_ownsHotspot) return _system.hostCount > 0 ? AHSPhaseServing : AHSPhaseWaiting;
    if (_system.hotspotOn && !(_pendingOff && now - _lastActionAt < kActionSettle)) return AHSPhaseForeignHotspot;
    if (_manualOpenRequested) return AHSPhaseSearching;
    if (now < _cooldownUntil) return AHSPhaseCooldown;
    if (!_autoWiFiPower && !_system.wifiPowered) return AHSPhaseWiFiOff;
    if (!_scanner.poweredOn) return _scanner.stateKnown ? AHSPhaseBluetoothOff : AHSPhaseStarting;
    return AHSPhaseSearching;
}

- (void)evaluate {
    NSTimeInterval now = AHSNow();
    if (_system.wifiConnected != _rawWiFiConnected) {
        _rawWiFiConnected = _system.wifiConnected;
        _wifiConnectedSince = _rawWiFiConnected ? now : 0;
        AHSLog(@"Wi‑Fi %@ (%@)", _rawWiFiConnected ? @"连上" : @"断开", _system.wifiDetail);
        if (_rawWiFiConnected) AHSAfter(kWiFiDebounce + 0.5, ^{ [self evaluate]; });
    }
    // Clients may have left just now; the idle clock starts when they do.
    if (_phase == AHSPhaseServing || _system.hostCount > 0) _lastClientAt = now;
    if (_pendingOff && !_system.hotspotOn) _pendingOff = NO;

    if (_ownsHotspot && !_system.hotspotOn && now - _lastActionAt > kActionSettle) {
        AHSLog(@"热点不是被本插件关掉的 (%@)，冷却 %.0f 分钟", _system.hotspotDebugState, _cooldown / 60);
        _ownsHotspot = NO;
        _manualSession = NO;
        _cooldownUntil = now + _cooldown;
        [self restoreWiFiPower];
        [self recordEvent:@"热点被手动关闭，进入冷却"];
        [self saveState];
    }

    AHSPhase phase = [self phaseAt:now];
    switch (phase) {
        case AHSPhaseDisabled:
            _manualOpenRequested = NO;
            if (_ownsHotspot) [self turnOffHotspot:@"功能已关闭" cooldown:NO];
            break;
        case AHSPhaseOnWiFi:
            _manualOpenRequested = NO;
            if (_ownsHotspot) [self turnOffHotspot:@"已连接 Wi‑Fi" cooldown:NO];
            // The radio we powered on is now in real use; leave it on.
            if (_poweredWiFi) {
                _poweredWiFi = NO;
                [self saveState];
            }
            break;
        case AHSPhaseLowBattery:
            if (_ownsHotspot) {
                [self turnOffHotspot:[NSString stringWithFormat:@"电量低 (%ld%%%@)", (long)_system.batteryLevel,
                                      _system.lowPowerMode ? @"，低电量模式" : @""] cooldown:NO];
            }
            break;
        case AHSPhaseOutsideSchedule:
            if (_ownsHotspot) [self turnOffHotspot:@"定时时段结束" cooldown:NO];
            break;
        case AHSPhaseWaiting:
            [self handleWaitingAt:now];
            break;
        case AHSPhaseSearching:
            // A Wi-Fi association still inside its debounce window may be real; don't race it.
            if (_manualOpenRequested || (!_rawWiFiConnected && now - _lastSeen <= _searchInterval + kScanWindow)) {
                [self turnOnHotspotAt:now];
            }
            break;
        default:
            break;
    }
    [self enterPhase:[self phaseAt:now]];
}

- (void)handleWaitingAt:(NSTimeInterval)now {
    NSTimeInterval idleSince = MAX(_onSince, _lastClientAt);
    BOOL airNearby = now - _lastSeen < _leaveDelay;
    if (!airNearby && now - idleSince >= _leaveDelay) {
        [self turnOffHotspot:@"Air 已离开" cooldown:NO];
    } else if (now - idleSince >= _idleTimeout) {
        [self turnOffHotspot:@"Air 在附近但一直没连热点" cooldown:YES];
    } else if (_system.hotspotOn && !_system.discoveryEnabled && now - _lastActionAt > 5) {
        AHSLog(@"热点不可被发现，重新开启发现 (%@)", _system.hotspotDebugState);
        [_system setDiscoveryEnabled:YES];
        _lastActionAt = now;
    }
}

- (void)turnOnHotspotAt:(NSTimeInterval)now {
    BOOL mayPowerWiFi = _autoWiFiPower || _manualOpenRequested;
    if (!_system.wifiPowered && mayPowerWiFi && now - _wifiPowerRequestedAt > kWiFiPowerRetry) {
        AHSLog(@"Wi‑Fi 是关的，先打开 Wi‑Fi 射频");
        [_system setWiFiPowered:YES];
        _poweredWiFi = YES;
        _wifiPowerRequestedAt = now;
        [self saveState];
        AHSAfter(kWiFiPowerSettle + 0.5, ^{ [self evaluate]; });
        return;
    }
    if (now - _wifiPowerRequestedAt < kWiFiPowerSettle) return;

    BOOL manual = _manualOpenRequested;
    if (manual) AHSLog(@"打开热点 (手动)");
    else AHSLog(@"打开热点 (Air %ld dBm)", (long)_lastRSSI);
    [_system setHotspotEnabled:YES];
    _ownsHotspot = YES;
    _manualSession = manual;
    _manualOpenRequested = NO;
    _pendingOff = NO;
    _onSince = now;
    _lastClientAt = 0;
    _lastActionAt = now;
    [self recordEvent:manual ? @"手动打开热点" : @"Air 在附近，打开热点"];
    [self saveState];
}

- (void)turnOffHotspot:(NSString *)reason cooldown:(BOOL)cooldown {
    NSTimeInterval now = AHSNow();
    AHSLog(@"关闭热点: %@", reason);
    [_system setHotspotEnabled:NO];
    _ownsHotspot = NO;
    _manualSession = NO;
    _manualOpenRequested = NO;
    _pendingOff = YES;
    _lastActionAt = now;
    if (cooldown) {
        _cooldownUntil = now + _cooldown;
        AHSLog(@"冷却 %.0f 分钟内不再自动打开", _cooldown / 60);
    }
    [self restoreWiFiPower];
    [self recordEvent:[NSString stringWithFormat:@"关闭热点：%@", reason]];
    [self saveState];
}

- (void)restoreWiFiPower {
    if (!_poweredWiFi) return;
    _poweredWiFi = NO;
    AHSAfter(2, ^{
        if (!self->_system.wifiConnected && !self->_ownsHotspot) {
            AHSLog(@"恢复 Wi‑Fi 关闭状态");
            [self->_system setWiFiPowered:NO];
        }
    });
}

#pragma mark - Phase effects

- (void)enterPhase:(AHSPhase)phase {
    if (phase != _phase) {
        AHSLog(@"状态: %@ → %@ (%@)", AHSPhaseDescription(_phase), AHSPhaseDescription(phase), _system.hotspotDebugState);
        _phase = phase;
        [self applyScanPolicy];
    }
    [self scheduleTick];
    [self saveStatusIfChanged];
}

- (void)applyScanPolicy {
    NSTimeInterval interval = 0;
    if (_phase == AHSPhaseSearching) interval = _searchInterval;
    else if (_phase == AHSPhaseWaiting) interval = MAX(kMinWaitingInterval, _searchInterval);
    if (interval == _scanInterval) return;

    _scanInterval = interval;
    NSUInteger generation = ++_scanGeneration;
    if (interval == 0) {
        [_scanner setScanning:NO];
        return;
    }
    [self runScanCycle:generation];
}

- (void)runScanCycle:(NSUInteger)generation {
    if (generation != _scanGeneration) return;
    _sightingLogged = NO;
    [_scanner setScanning:YES];
    AHSAfter(kScanWindow, ^{
        if (generation != self->_scanGeneration) return;
        [self->_scanner setScanning:NO];
        [self evaluate];
    });
    AHSAfter(_scanInterval, ^{ [self runScanCycle:generation]; });
}

// Seconds until the schedule can next flip: its start, its end, or midnight (weekday change).
- (NSTimeInterval)secondsUntilScheduleBoundary {
    NSDate *now = [NSDate date];
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:now];
    NSInteger secondOfDay = (c.hour * 60 + c.minute) * 60 + c.second;
    NSTimeInterval best = 86400;
    for (NSNumber *minute in @[ @(_scheduleStart), @(_scheduleEnd), @0 ]) {
        NSInteger delta = (minute.integerValue * 60 - secondOfDay + 86400) % 86400;
        if (delta > 0 && delta < best) best = delta;
    }
    return best;
}

- (void)scheduleTick {
    NSTimeInterval delay = DBL_MAX;
    if (_phase == AHSPhaseCooldown) delay = MAX(1, _cooldownUntil - AHSNow() + 1);
    else if (_phase == AHSPhaseWaiting) delay = kWaitingTick;
    if (_enabled && _scheduleEnabled) delay = MIN(delay, [self secondsUntilScheduleBoundary] + 1);
    if (delay == DBL_MAX) return;
    NSUInteger generation = ++_tickGeneration;
    AHSAfter(delay, ^{
        if (generation == self->_tickGeneration) [self evaluate];
    });
}

- (void)saveStatusIfChanged {
    NSString *signature = [NSString stringWithFormat:@"%ld|%d|%ld|%@|%@|%ld|%ld|%d", (long)_phase, _ownsHotspot,
                           (long)_system.hostCount, _lastEvent, _deviceIdentifiers.firstObject, (long)(_lastSeen / 60),
                           (long)_system.batteryLevel, _system.externalPower];
    if ([signature isEqualToString:_statusSignature]) return;
    _statusSignature = signature;
    [self saveState];
}
@end
