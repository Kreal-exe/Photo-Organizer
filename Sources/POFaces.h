#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Length of a face embedding: one signed byte per dimension, the unit vector scaled to ±127.
FOUNDATION_EXPORT const NSInteger POFaceEmbeddingLength;

/// Finds the faces in a picture (Vision, built into macOS), straightens each one by its eyes and mouth, and
/// turns it into an embedding with the downloaded ArcFace model, so that faces of one person can be grouped.
@interface POFaceEmbedder : NSObject

/// Starts the model; do it off the main thread. Fails when the model or MLX is not installed.
+ (nullable instancetype)embedderWithError:(NSError **)error;

/// One embedding per usable face, largest faces first; empty when there are none. Thread-safe.
/// `peopleCount` receives the number of people in the picture (see +peopleCountInImage:).
- (NSArray<NSData *> *)embeddingsForFacesInImage:(CGImageRef)image peopleCount:(nullable NSInteger *)peopleCount;

/// Every face Vision finds (also those too small or blurred to embed) or every human figure, whichever is more:
/// people seen from the back or in the dark often have no detectable face.
+ (NSInteger)peopleCountInImage:(CGImageRef)image;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
