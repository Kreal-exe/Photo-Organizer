#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Sheet showing a photo on which the user marks the object to look for: drag a frame around it. The object
/// Vision finds most prominent is framed to begin with.
@interface POObjectPickerController : NSViewController

/// `image` is the photo, upright; `initialRect` (pixels, origin top-left) the frame to start with, or CGRectNull.
- (instancetype)initWithImage:(CGImageRef)image initialRect:(CGRect)initialRect;

/// Called after the sheet closes with the chosen frame (pixels, origin top-left), unless it was cancelled.
@property (nonatomic, copy, nullable) void (^completion)(CGRect rect);

@end

NS_ASSUME_NONNULL_END
