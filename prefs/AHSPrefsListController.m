#import "AHSPrefsListController.h"
#import <notify.h>
#import "../shared/AHSShared.h"

@implementation AHSPrefsListController

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, AHSPrefsDomain));
    return value ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    // An emptied text field means "back to the default".
    if ([value isKindOfClass:[NSString class]] && [value length] == 0) value = nil;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, AHSPrefsDomain);
    CFPreferencesAppSynchronize(AHSPrefsDomain);
    notify_post(AHSPrefsChangedNotification);
}
@end
