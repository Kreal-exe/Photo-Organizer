#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A model running in the MLX helper process (Resources/vit_mlx.py): takes square RGB images, returns one
/// line of text per image. Creating one starts the process and loads the weights — do it off the main thread.
@interface POMLXImageModel : NSObject

/// `embedding` selects the helper's mode: NO for a classifier's probability, YES for an embedding vector.
- (nullable instancetype)initWithSnapshotURL:(NSURL *)snapshot embedding:(BOOL)embedding error:(NSError **)error;

/// Side of the square input, in pixels.
@property (nonatomic, readonly) NSInteger inputSize;

/// Sends `inputSize`×`inputSize`×3 bytes of RGB and returns the helper's reply; nil when it has died.
/// Thread-safe, one image at a time.
- (nullable NSString *)replyForRGBData:(NSData *)pixels;

- (void)invalidate;

@end

/// Draws `image` into a size×size RGB buffer (3 bytes per pixel, top row first) through `transform`, which
/// maps image coordinates (origin bottom-left) to the buffer's.
FOUNDATION_EXPORT NSData *_Nullable PORGBDataWithTransform(CGImageRef image, NSInteger size, CGAffineTransform transform);

NS_ASSUME_NONNULL_END
