#import <Preferences/PSViewController.h>
#import <roothide.h>
#import "../shared/AHSShared.h"

static const NSUInteger kShownLines = 400;

@interface AHSLogViewController : PSViewController
@end

@implementation AHSLogViewController {
    UITextView *_textView;
}

- (void)loadView {
    _textView = [UITextView new];
    _textView.editable = NO;
    _textView.alwaysBounceVertical = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _textView.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
    _textView.backgroundColor = [UIColor systemBackgroundColor];
    self.view = _textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"日志";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self action:@selector(reload)];
    [self reload];
}

- (void)reload {
    NSString *text = [NSString stringWithContentsOfFile:jbroot(@AHSLogFile) encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) {
        _textView.text = @"还没有日志，或者读取不到日志文件。";
        return;
    }
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count > kShownLines) lines = [lines subarrayWithRange:NSMakeRange(lines.count - kShownLines, kShownLines)];
    _textView.text = [lines componentsJoinedByString:@"\n"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_textView scrollRangeToVisible:NSMakeRange(self->_textView.text.length, 0)];
    });
}
@end
