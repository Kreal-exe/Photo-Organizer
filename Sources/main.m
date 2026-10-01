#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import <signal.h>

int main(int argc, const char *argv[]) {
    // Writing to a helper process that has died must return an error, not kill the app.
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];   // NSApplication holds its delegate weakly
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
