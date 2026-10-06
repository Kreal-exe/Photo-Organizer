#import <Cocoa/Cocoa.h>
#import "POActions.h"

NS_ASSUME_NONNULL_BEGIN

/// The folders whose scan or recognition was still running when the app quit (an array of paths, or one path from
/// older versions); they are opened again at launch.
FOUNDATION_EXPORT NSString *const POUnfinishedFolderKey;

/// Owns the window and drives the whole flow: pick folder → scan → preview plan → move files → undo.
@interface MainWindowController : NSWindowController <POActions>

- (instancetype)init;

/// Starts scanning `url` (or its parent folder when `url` is a file).
- (void)loadFolder:(NSURL *)url;
/// Opens a library of one or more folders, scanned and organized together.
- (void)loadFolders:(NSArray<NSURL *> *)urls;

@end

NS_ASSUME_NONNULL_END
