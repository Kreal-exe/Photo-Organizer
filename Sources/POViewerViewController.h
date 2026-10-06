#import <Cocoa/Cocoa.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Full-size viewer shown in place of the grid: zoomable images, playable videos, ←/→ to step through
/// the list, Esc to go back.
@interface POViewerViewController : NSViewController

/// Called when the user leaves the viewer, with the item that was on screen.
@property (nonatomic, copy, nullable) void (^onClose)(POPhotoItem *_Nullable item);

/// The right-click menu for the file on screen.
@property (nonatomic, copy, nullable) NSMenu *_Nullable (^menuProvider)(POPhotoItem *item);

- (void)showItems:(NSArray<POPhotoItem *> *)items atIndex:(NSUInteger)index;

/// The file on screen; nil when there is none.
@property (nonatomic, readonly, nullable) POPhotoItem *currentItem;

/// Stops playback and releases the media. Call when the viewer is hidden.
- (void)stop;

/// Leaves the viewer (calls `onClose`).
- (void)close;

/// YES while an image (not a video) is on screen.
@property (nonatomic, readonly) BOOL canZoom;
- (void)zoomIn;
- (void)zoomOut;
- (void)zoomToActualSize;
- (void)zoomToFit;

@end

NS_ASSUME_NONNULL_END
