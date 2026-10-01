#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "POModel.h"

NS_ASSUME_NONNULL_BEGIN

/// Runs a downloaded nudity model. Creating one loads the model (and, for MLX, starts the helper process), so
/// do it off the main thread.
@interface PONudityClassifier : NSObject

+ (nullable instancetype)classifierWithModel:(POModel *)model error:(NSError **)error;

@property (nonatomic, readonly) POModel *model;

/// Probability (0…1) that the image is explicit; nil when the model failed. Thread-safe, one image at a time.
- (nullable NSNumber *)scoreForImage:(CGImageRef)image;

/// Stops the helper process. The classifier can't be used afterwards.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
