#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

// A row whose value is minutes after midnight, edited with a compact time picker.
@interface AHSTimeCell : PSTableCell
@end

@implementation AHSTimeCell {
    UIDatePicker *_picker;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        _picker = [UIDatePicker new];
        _picker.datePickerMode = UIDatePickerModeTime;
        _picker.preferredDatePickerStyle = UIDatePickerStyleCompact;
        _picker.minuteInterval = 5;
        [_picker addTarget:self action:@selector(pickerChanged:) forControlEvents:UIControlEventValueChanged];
        [_picker sizeToFit];
        self.accessoryView = _picker;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    id target = specifier.target;
    id value = [target respondsToSelector:@selector(readPreferenceValue:)] ? [target readPreferenceValue:specifier] : nil;
    NSInteger minutes = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *date = [calendar dateBySettingHour:minutes / 60 minute:minutes % 60 second:0 ofDate:[NSDate date] options:0];
    if (date) _picker.date = date;
}

- (void)pickerChanged:(UIDatePicker *)picker {
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:picker.date];
    id target = self.specifier.target;
    if ([target respondsToSelector:@selector(setPreferenceValue:specifier:)]) {
        [target setPreferenceValue:@(c.hour * 60 + c.minute) specifier:self.specifier];
    }
}
@end
