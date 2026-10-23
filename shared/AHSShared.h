// Shared between autohotspotd and the Settings pane.
#pragma once
#import <Foundation/Foundation.h>

#define AHSPrefsDomain CFSTR("com.xcode.autohotspot")
#define AHSPrefsChangedNotification "com.xcode.autohotspot/prefs-changed"
#define AHSRelearnNotification "com.xcode.autohotspot/relearn"
#define AHSStatusChangedNotification "com.xcode.autohotspot/status-changed"
#define AHSOpenNowNotification "com.xcode.autohotspot/open-now"
#define AHSCloseNowNotification "com.xcode.autohotspot/close-now"

// jbroot-relative; resolve with jbroot() before use.
#define AHSStateFile "/var/lib/autohotspot/state.plist"
#define AHSLogFile "/var/log/autohotspot.log"

// Settings (written by the Settings pane as user mobile).
#define AHSKeyEnabled @"enabled"
#define AHSKeyRSSIThreshold @"rssiThreshold"
#define AHSKeyLeaveDelay @"leaveDelay"
#define AHSKeyIdleTimeout @"idleTimeout"
#define AHSKeyCooldown @"cooldown"
#define AHSKeyTargetModel @"targetModel"
#define AHSKeyScanInterval @"scanInterval"
#define AHSKeyAutoWiFiPower @"autoWiFiPower"
#define AHSKeyLowBatteryThreshold @"lowBatteryThreshold"
#define AHSKeyPauseInLowPowerMode @"pauseInLowPowerMode"
#define AHSKeyScheduleEnabled @"scheduleEnabled"
#define AHSKeyScheduleStart @"scheduleStart"
#define AHSKeyScheduleEnd @"scheduleEnd"
// Followed by an NSCalendar weekday: 1 = Sunday … 7 = Saturday.
#define AHSKeyScheduleWeekdayPrefix @"scheduleWeekday"

#define AHSDefaultRSSIThreshold (-80)
#define AHSDefaultLeaveDelay 180
#define AHSDefaultIdleTimeout 300
#define AHSDefaultCooldown 1800
#define AHSDefaultTargetModel @"iPhone18,4"
#define AHSDefaultScanInterval 15
#define AHSDefaultLowBatteryThreshold 20
#define AHSDefaultScheduleStart (8 * 60)
#define AHSDefaultScheduleEnd (22 * 60)

// State file (written by the daemon only).
#define AHSStateOwnsHotspot @"ownsHotspot"
#define AHSStatePoweredWiFi @"poweredWiFi"
#define AHSStateCooldownUntil @"cooldownUntil"
#define AHSStateDeviceIdentifiers @"deviceIdentifiers"
#define AHSStateDeviceName @"deviceName"
#define AHSStatePhase @"phase"
#define AHSStateLastSeen @"lastSeen"
#define AHSStateLastRSSI @"lastRSSI"
#define AHSStateHostCount @"hostCount"
#define AHSStateBatteryLevel @"batteryLevel"
#define AHSStateCharging @"charging"
#define AHSStateUpdatedAt @"updatedAt"
#define AHSStateLastEvent @"lastEvent"

typedef NS_ENUM(NSInteger, AHSPhase) {
    AHSPhaseStarting = 0,
    AHSPhaseDisabled,
    AHSPhaseOnWiFi,
    AHSPhaseForeignHotspot,
    AHSPhaseCooldown,
    AHSPhaseBluetoothOff,
    AHSPhaseSearching,
    AHSPhaseServing,
    AHSPhaseWaiting,
    AHSPhaseOutsideSchedule,
    AHSPhaseLowBattery,
    AHSPhaseWiFiOff,
};

static inline NSString *AHSPhaseDescription(AHSPhase phase) {
    switch (phase) {
        case AHSPhaseStarting: return @"启动中";
        case AHSPhaseDisabled: return @"已关闭";
        case AHSPhaseOnWiFi: return @"已连接 Wi‑Fi，待机";
        case AHSPhaseForeignHotspot: return @"热点是手动打开的，不干预";
        case AHSPhaseCooldown: return @"冷却中";
        case AHSPhaseBluetoothOff: return @"蓝牙未开启";
        case AHSPhaseSearching: return @"正在寻找 Air";
        case AHSPhaseServing: return @"热点已开，Air 已连接";
        case AHSPhaseWaiting: return @"热点已开，等待 Air 连接";
        case AHSPhaseOutsideSchedule: return @"不在定时时段内";
        case AHSPhaseLowBattery: return @"电量低，暂停";
        case AHSPhaseWiFiOff: return @"Wi‑Fi 已关闭（未允许自动打开）";
    }
    return @"未知";
}

// Weekday bitmask: bit n set = NSCalendar weekday n enabled.
static inline BOOL AHSScheduleContains(NSDate *date, NSInteger start, NSInteger end, NSInteger weekdays) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *c = [calendar components:NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute fromDate:date];
    NSInteger minute = c.hour * 60 + c.minute;
    NSInteger today = c.weekday;
    NSInteger yesterday = today == 1 ? 7 : today - 1;
    BOOL todayOn = (weekdays >> today) & 1;
    BOOL yesterdayOn = (weekdays >> yesterday) & 1;
    if (start == end) return todayOn;
    if (start < end) return todayOn && minute >= start && minute < end;
    // Overnight range: the part after midnight belongs to the day it started.
    return (todayOn && minute >= start) || (yesterdayOn && minute < end);
}

static inline NSString *AHSWeekdaysSummary(NSInteger weekdays) {
    NSInteger all = 0xFE, workdays = 0x7C, weekend = 0x82;
    weekdays &= all;
    if (weekdays == all) return @"每天";
    if (weekdays == workdays) return @"工作日";
    if (weekdays == weekend) return @"周末";
    if (weekdays == 0) return @"从不";
    NSArray *names = @[ @"", @"日", @"一", @"二", @"三", @"四", @"五", @"六" ];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSInteger day = 2; day <= 8; day++) {
        NSInteger weekday = day == 8 ? 1 : day;
        if ((weekdays >> weekday) & 1) [parts addObject:names[weekday]];
    }
    return [@"周" stringByAppendingString:[parts componentsJoinedByString:@"、"]];
}

static inline NSString *AHSMinutesText(NSInteger minutes) {
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)(minutes / 60), (long)(minutes % 60)];
}
