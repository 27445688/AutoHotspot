#import <Foundation/Foundation.h>

// Decides when to turn the hotspot on/off. Runs entirely on the main queue.
@interface AHSController : NSObject
// One-shot for package removal: turns off a hotspot the daemon opened, then returns.
+ (void)releaseOwnedHotspot;
- (BOOL)start;
- (void)shutdown;
@end
