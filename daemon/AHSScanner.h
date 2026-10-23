#import <Foundation/Foundation.h>

// BLE presence of the target phone. Matches by learned peripheral identifier or by
// the device name bluetoothd resolves for same-Apple-ID devices. With nothing learned
// yet, it connects to nearby Apple devices and reads the DIS model number.
@interface AHSScanner : NSObject
@property (nonatomic, copy) void (^stateHandler)(void);
@property (nonatomic, copy) void (^sightingHandler)(NSUUID *identifier, NSInteger rssi);
@property (nonatomic, copy) void (^learnedHandler)(NSUUID *identifier, NSString *name);
@property (nonatomic, copy) NSArray<NSString *> *targetIdentifiers;
@property (nonatomic, copy) NSString *targetName;
@property (nonatomic, copy) NSString *targetModel;
@property (nonatomic, readonly) BOOL poweredOn;
@property (nonatomic, readonly) BOOL stateKnown;
@property (nonatomic, readonly) BOOL scanning;

- (void)setScanning:(BOOL)scanning;
@end
