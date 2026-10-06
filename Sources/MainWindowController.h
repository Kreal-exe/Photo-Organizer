#import <Cocoa/Cocoa.h>
#import "POActions.h"

NS_ASSUME_NONNULL_BEGIN

/// The folder whose scan or recognition was still running when the app quit; it is opened again at launch.
FOUNDATION_EXPORT NSString *const POUnfinishedFolderKey;

/// Owns the window and drives the whole flow: pick folder → scan → preview plan → move files → undo.
@interface MainWindowController : NSWindowController <POActions>

- (instancetype)init;

/// Starts scanning `url` (or its parent folder when `url` is a file).
- (void)loadFolder:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
