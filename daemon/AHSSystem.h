#import <Foundation/Foundation.h>

// Wi-Fi association, Wi-Fi power and Personal Hotspot state/control.
// All callbacks arrive on the main queue.
@interface AHSSystem : NSObject
@property (nonatomic, copy) void (^changeHandler)(void);
@property (nonatomic, readonly) BOOL wifiConnected;
@property (nonatomic, readonly) NSString *wifiDetail;
@property (nonatomic, readonly) BOOL hotspotOn;
@property (nonatomic, readonly) NSInteger hostCount;
@property (nonatomic, readonly) BOOL wifiPowered;
@property (nonatomic, readonly) BOOL discoveryEnabled;
@property (nonatomic, readonly) NSString *hotspotDebugState;
// -1 when the power source cannot be read.
@property (nonatomic, readonly) NSInteger batteryLevel;
// Plugged in, whether or not the battery is still filling.
@property (nonatomic, readonly) BOOL externalPower;
@property (nonatomic, readonly) BOOL lowPowerMode;

- (BOOL)start;
- (void)setWiFiPowered:(BOOL)powered;
- (void)setHotspotEnabled:(BOOL)enabled;
- (void)setDiscoveryEnabled:(BOOL)enabled;
@end
