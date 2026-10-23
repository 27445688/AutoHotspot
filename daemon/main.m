#import <Foundation/Foundation.h>
#import "AHSController.h"
#import "AHSLog.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        AHSLogSetup();
        if (argc > 1 && strcmp(argv[1], "--release") == 0) {
            [AHSController releaseOwnedHotspot];
            return 0;
        }
        AHSLog(@"autohotspotd 启动 (pid %d)", getpid());

        AHSController *controller = [AHSController new];
        if (![controller start]) {
            // Exit slowly so launchd's KeepAlive does not spin on a missing system API.
            AHSLog(@"初始化失败，60 秒后退出");
            sleep(60);
            return 1;
        }

        // launchctl unload sends SIGKILL on this device; this only covers system shutdown.
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{
            [controller shutdown];
            exit(0);
        });
        dispatch_resume(term);

        // WiFiKit and MISManager deliver callbacks through the main run loop.
        CFRunLoopRun();
    }
    return 0;
}
