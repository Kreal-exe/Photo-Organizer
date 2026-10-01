#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The Settings window: object search (built into macOS) and the optional nudity detection with its
/// downloadable models.
@interface POSettingsWindowController : NSWindowController

@property (class, nonatomic, readonly) POSettingsWindowController *sharedController;

/// Opens the window on a pane: 0 general, 1 recognition, 2 nudity.
- (void)showPaneAtIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
