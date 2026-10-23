#import "AHSLog.h"
#import "../shared/AHSShared.h"
#import <roothide.h>

static NSString *gLogPath;
static NSDateFormatter *gFormatter;
static const unsigned long long kMaxLogSize = 512 * 1024;

void AHSLogSetup(void) {
    gLogPath = jbroot(@AHSLogFile);
    [[NSFileManager defaultManager] createDirectoryAtPath:gLogPath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    gFormatter = [NSDateFormatter new];
    gFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
}

void AHSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [gFormatter stringFromDate:[NSDate date]], message];
    fputs(line.UTF8String, stderr);
    if (!gLogPath) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm attributesOfItemAtPath:gLogPath error:nil].fileSize > kMaxLogSize) {
        NSString *rotated = [gLogPath stringByAppendingString:@".1"];
        [fm removeItemAtPath:rotated error:nil];
        [fm moveItemAtPath:gLogPath toPath:rotated error:nil];
    }
    FILE *file = fopen(gLogPath.fileSystemRepresentation, "a");
    if (file) {
        fputs(line.UTF8String, file);
        fclose(file);
    }
}
