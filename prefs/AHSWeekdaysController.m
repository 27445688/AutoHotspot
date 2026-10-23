#import "AHSPrefsListController.h"
#import <Preferences/PSTableCell.h>
#import "../shared/AHSShared.h"

@interface AHSWeekdaysController : AHSPrefsListController
@end

@implementation AHSWeekdaysController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
        [group setProperty:@"关掉的那天不自动开热点。跨夜时段（比如 22:00–07:00）过了零点的部分算前一天。" forKey:@"footerText"];
        [specifiers addObject:group];

        NSArray *names = @[ @"周一", @"周二", @"周三", @"周四", @"周五", @"周六", @"周日" ];
        NSArray *weekdays = @[ @2, @3, @4, @5, @6, @7, @1 ];
        for (NSUInteger i = 0; i < names.count; i++) {
            PSSpecifier *day = [PSSpecifier preferenceSpecifierNamed:names[i] target:self set:@selector(setPreferenceValue:specifier:)
                                                                 get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
            [day setProperty:[AHSKeyScheduleWeekdayPrefix stringByAppendingFormat:@"%@", weekdays[i]] forKey:@"key"];
            [day setProperty:@YES forKey:@"default"];
            [specifiers addObject:day];
        }
        _specifiers = specifiers;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"重复";
}
@end
