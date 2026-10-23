#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// Reads and writes the com.xcode.autohotspot domain directly and pokes the daemon on every change.
@interface AHSPrefsListController : PSListController
@end
