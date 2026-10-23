#import "AHSPrefsListController.h"
#import <notify.h>
#import <roothide.h>
#import "../shared/AHSShared.h"

@interface AHSRootListController : AHSPrefsListController
@end

@implementation AHSRootListController {
    int _statusToken;
    NSTimer *_refreshTimer;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        NSString *version = [[NSBundle bundleForClass:[self class]] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        [[self specifierForID:@"aboutGroup"] setProperty:[NSString stringWithFormat:@"AutoHotspot %@", version ?: @""] forKey:@"footerText"];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    __weak AHSRootListController *weakSelf = self;
    notify_register_dispatch(AHSStatusChangedNotification, &_statusToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf refreshStatus];
    });
    // Keeps the "seen N seconds ago" line honest between daemon updates.
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshStatus];
    }];
    [self refreshRepeatSummary];
    [self refreshStatus];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    notify_cancel(_statusToken);
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    [self refreshStatus];
}

#pragma mark - Reading prefs and state

- (id)prefValue:(NSString *)key {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, AHSPrefsDomain));
}

- (NSInteger)prefInteger:(NSString *)key fallback:(NSInteger)fallback {
    id value = [self prefValue:key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

- (NSInteger)scheduleWeekdays {
    NSInteger weekdays = 0;
    for (NSInteger weekday = 1; weekday <= 7; weekday++) {
        id value = [self prefValue:[AHSKeyScheduleWeekdayPrefix stringByAppendingFormat:@"%ld", (long)weekday]];
        if (!value || [value boolValue]) weekdays |= 1 << weekday;
    }
    return weekdays;
}

static NSString *AHSAgo(NSTimeInterval timestamp) {
    NSTimeInterval seconds = MAX([NSDate date].timeIntervalSince1970 - timestamp, 0);
    if (seconds < 60) return [NSString stringWithFormat:@"%.0f 秒前", seconds];
    if (seconds < 3600) return [NSString stringWithFormat:@"%.0f 分钟前", seconds / 60];
    return [NSString stringWithFormat:@"%.1f 小时前", seconds / 3600];
}

- (void)refreshStatus {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:jbroot(@AHSStateFile)];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (!state) {
        [lines addObject:@"读取不到后台服务状态（服务可能没在运行）"];
    } else {
        AHSPhase phase = [state[AHSStatePhase] integerValue];
        NSString *phaseText = AHSPhaseDescription(phase);
        if (phase == AHSPhaseCooldown) {
            NSDate *until = [NSDate dateWithTimeIntervalSince1970:[state[AHSStateCooldownUntil] doubleValue]];
            phaseText = [phaseText stringByAppendingFormat:@"（到 %@）",
                         [NSDateFormatter localizedStringFromDate:until dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
        }
        [lines addObject:[NSString stringWithFormat:@"状态：%@", phaseText]];
        [lines addObject:[NSString stringWithFormat:@"热点连接数：%@", state[AHSStateHostCount] ?: @0]];
        double lastSeen = [state[AHSStateLastSeen] doubleValue];
        [lines addObject:lastSeen > 0
            ? [NSString stringWithFormat:@"最近看到 Air：%@（%@ dBm）", AHSAgo(lastSeen), state[AHSStateLastRSSI]]
            : @"最近看到 Air：还没有"];
        NSInteger battery = [state[AHSStateBatteryLevel] integerValue];
        if (state[AHSStateBatteryLevel] && battery >= 0) {
            [lines addObject:[NSString stringWithFormat:@"本机电量：%ld%%%@", (long)battery, [state[AHSStateCharging] boolValue] ? @"（接着电源）" : @""]];
        }
    }
    if ([[self prefValue:AHSKeyScheduleEnabled] boolValue]) {
        NSInteger start = [self prefInteger:AHSKeyScheduleStart fallback:AHSDefaultScheduleStart];
        NSInteger end = [self prefInteger:AHSKeyScheduleEnd fallback:AHSDefaultScheduleEnd];
        NSInteger weekdays = [self scheduleWeekdays];
        BOOL inside = AHSScheduleContains([NSDate date], start, end, weekdays);
        [lines addObject:[NSString stringWithFormat:@"定时：%@–%@ %@（现在%@时段内）", AHSMinutesText(start), AHSMinutesText(end),
                          AHSWeekdaysSummary(weekdays), inside ? @"在" : @"不在"]];
    }
    if (state[AHSStateLastEvent]) [lines addObject:[NSString stringWithFormat:@"最近事件：%@", state[AHSStateLastEvent]]];
    [self setFooter:[lines componentsJoinedByString:@"\n"] forGroupID:@"statusGroup"];

    NSArray *identifiers = state[AHSStateDeviceIdentifiers];
    NSString *name = state[AHSStateDeviceName];
    NSString *model = [self prefValue:AHSKeyTargetModel] ?: AHSDefaultTargetModel;
    NSString *device = identifiers.count
        ? [NSString stringWithFormat:@"已识别：%@\n%@\n换了手机就改型号，再点「重新识别」。", name.length ? name : @"(无名称)", identifiers.firstObject]
        : [NSString stringWithFormat:@"尚未识别。本机没连 Wi‑Fi 时，带着型号 %@ 的手机靠近就会自动识别。", model];
    [self setFooter:device forGroupID:@"deviceGroup"];
}

- (void)refreshRepeatSummary {
    PSSpecifier *repeat = [self specifierForID:@"repeat"];
    NSString *name = [NSString stringWithFormat:@"重复：%@", AHSWeekdaysSummary([self scheduleWeekdays])];
    if (!repeat || [repeat.name isEqualToString:name]) return;
    repeat.name = name;
    [self reloadSpecifier:repeat animated:NO];
}

- (void)setFooter:(NSString *)text forGroupID:(NSString *)identifier {
    PSSpecifier *group = [self specifierForID:identifier];
    if (!group || [[group propertyForKey:@"footerText"] isEqualToString:text]) return;
    [group setProperty:text forKey:@"footerText"];
    [self reloadSpecifier:group animated:NO];
}

#pragma mark - Actions

- (void)openNow:(PSSpecifier *)specifier {
    notify_post(AHSOpenNowNotification);
}

- (void)closeNow:(PSSpecifier *)specifier {
    notify_post(AHSCloseNowNotification);
}

- (void)relearn:(PSSpecifier *)specifier {
    notify_post(AHSRelearnNotification);
}
@end
