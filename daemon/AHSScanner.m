#import "AHSScanner.h"
#import "AHSLog.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <dlfcn.h>

static CBUUID *AHSDeviceInfoService(void) { return [CBUUID UUIDWithString:@"180A"]; }
static CBUUID *AHSModelNumberCharacteristic(void) { return [CBUUID UUIDWithString:@"2A24"]; }

static const NSTimeInterval kProbeTimeout = 10;
static const NSTimeInterval kRetryAfterFailure = 120;
static const NSTimeInterval kRetryAfterMismatch = 3600;
// Same-account devices carry a resolved name; unnamed ones must be very close to be worth probing.
static const NSInteger kProbeNamedMinRSSI = -75;
static const NSInteger kProbeUnnamedMinRSSI = -55;

// Without this private option bluetoothd treats a daemon as a background app and
// drops every result of a scan that has no service filter.
static NSString *AHSPrivateKey(const char *symbol) {
    NSString * __unsafe_unretained *key = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, symbol);
    return key ? *key : nil;
}

@interface AHSScanner () <CBCentralManagerDelegate, CBPeripheralDelegate>
@end

@implementation AHSScanner {
    CBCentralManager *_central;
    NSDictionary *_scanOptions;
    BOOL _wantScan;
    CBPeripheral *_probing;
    NSUInteger _probeGeneration;
    NSMutableDictionary<NSUUID *, NSDate *> *_skipUntil;
}

- (instancetype)init {
    if ((self = [super init])) {
        _skipUntil = [NSMutableDictionary dictionary];
        NSMutableDictionary *initOptions = [NSMutableDictionary dictionary];
        NSMutableDictionary *scanOptions = [@{ CBCentralManagerScanOptionAllowDuplicatesKey: @YES } mutableCopy];
        NSString *managerKey = AHSPrivateKey("CBManagerIsPrivilegedDaemonKey");
        NSString *scanKey = AHSPrivateKey("CBCentralManagerScanOptionIsPrivilegedDaemonKey");
        if (managerKey) initOptions[managerKey] = @YES;
        if (scanKey) scanOptions[scanKey] = @YES;
        if (!managerKey || !scanKey) AHSLog(@"警告: 缺少蓝牙特权选项，扫描可能收不到结果");
        _scanOptions = scanOptions;
        _central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:initOptions];
    }
    return self;
}

- (BOOL)poweredOn {
    return _central.state == CBManagerStatePoweredOn;
}

- (BOOL)stateKnown {
    return _central.state != CBManagerStateUnknown && _central.state != CBManagerStateResetting;
}

- (BOOL)scanning {
    return _central.isScanning;
}

- (void)setScanning:(BOOL)scanning {
    _wantScan = scanning;
    [self applyScanState];
}

- (void)applyScanState {
    if (!self.poweredOn) return;
    if (_wantScan && !_central.isScanning) {
        [_central scanForPeripheralsWithServices:nil options:_scanOptions];
    } else if (!_wantScan && _central.isScanning) {
        [_central stopScan];
    }
}

- (BOOL)needsLearning {
    return self.targetIdentifiers.count == 0 && self.targetName.length == 0;
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    AHSLog(@"蓝牙状态: %ld", (long)central.state);
    [self applyScanState];
    if (self.stateHandler) self.stateHandler();
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData RSSI:(NSNumber *)RSSI {
    NSInteger rssi = RSSI.integerValue;
    if (rssi >= 0 || rssi == 127) return;

    NSString *uuid = peripheral.identifier.UUIDString;
    BOOL knownIdentifier = [self.targetIdentifiers containsObject:uuid];
    BOOL nameMatches = self.targetName.length > 0 && [peripheral.name isEqualToString:self.targetName];
    if (knownIdentifier || nameMatches) {
        if (!knownIdentifier && self.learnedHandler) self.learnedHandler(peripheral.identifier, peripheral.name);
        if (self.sightingHandler) self.sightingHandler(peripheral.identifier, rssi);
        return;
    }
    if (self.needsLearning) [self considerCandidate:peripheral advertisement:advertisementData rssi:rssi];
}

- (void)considerCandidate:(CBPeripheral *)peripheral advertisement:(NSDictionary *)advertisement rssi:(NSInteger)rssi {
    if (_probing) return;
    NSDate *skip = _skipUntil[peripheral.identifier];
    if (skip && skip.timeIntervalSinceNow > 0) return;

    NSData *manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey];
    if (manufacturer.length < 3) return;
    const uint8_t *bytes = manufacturer.bytes;
    if (bytes[0] != 0x4c || bytes[1] != 0x00) return;
    BOOL named = peripheral.name.length > 0;
    BOOL nearbyInfo = bytes[2] == 0x10;
    if (!(named && rssi >= kProbeNamedMinRSSI) && !(nearbyInfo && rssi >= kProbeUnnamedMinRSSI)) return;

    _probing = peripheral;
    NSUInteger generation = ++_probeGeneration;
    peripheral.delegate = self;
    AHSLog(@"识别候选设备 %@ (%@, %ld dBm)", peripheral.identifier.UUIDString, peripheral.name ?: @"无名称", (long)rssi);
    [_central connectPeripheral:peripheral options:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kProbeTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == self->_probeGeneration && self->_probing) {
            AHSLog(@"读取型号超时: %@", peripheral.identifier.UUIDString);
            [self finishProbeWithModel:nil];
        }
    });
}

- (void)finishProbeWithModel:(NSString *)model {
    CBPeripheral *peripheral = _probing;
    if (!peripheral) return;
    _probing = nil;
    _probeGeneration++;
    [_central cancelPeripheralConnection:peripheral];

    if (model && [model isEqualToString:self.targetModel]) {
        AHSLog(@"已识别目标设备 %@ (%@, %@)", peripheral.identifier.UUIDString, peripheral.name ?: @"无名称", model);
        if (self.learnedHandler) self.learnedHandler(peripheral.identifier, peripheral.name);
        return;
    }
    if (model) AHSLog(@"候选设备型号 %@ 不匹配 %@", model, self.targetModel);
    NSTimeInterval wait = model ? kRetryAfterMismatch : kRetryAfterFailure;
    _skipUntil[peripheral.identifier] = [NSDate dateWithTimeIntervalSinceNow:wait];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (peripheral != _probing) return;
    [peripheral discoverServices:@[ AHSDeviceInfoService() ]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral != _probing) return;
    AHSLog(@"连接候选设备失败: %@", error.localizedDescription);
    [self finishProbeWithModel:nil];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral == _probing) [self finishProbeWithModel:nil];
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:AHSDeviceInfoService()]) {
            [peripheral discoverCharacteristics:@[ AHSModelNumberCharacteristic() ] forService:service];
            return;
        }
    }
    [self finishProbeWithModel:nil];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:AHSModelNumberCharacteristic()]) {
            [peripheral readValueForCharacteristic:characteristic];
            return;
        }
    }
    [self finishProbeWithModel:nil];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != _probing || ![characteristic.UUID isEqual:AHSModelNumberCharacteristic()]) return;
    NSString *model = characteristic.value ? [[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding] : nil;
    [self finishProbeWithModel:model ?: @""];
}
@end
