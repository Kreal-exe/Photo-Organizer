#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Tells how an image was made rather than what is in it: taken by a camera (a photo — of people, of a notebook page,
/// of a screen), made on a computer (a picture — a postcard, a meme, an icon, a quote card) or put together from
/// several photos (a collage). The image labels of macOS can't: they say "document" for a photographed notebook and
/// "art" for a tattoo, and messenger photos keep no camera metadata to go by.
///
/// MobileCLIP (POModel.pictureModel) turns the image into a vector once, during the analysis; the vector is compared
/// with the vectors of descriptions of each kind ("a photo of a child", "a greeting card with text", "a grid of family
/// photos"…), computed beforehand by Tools/make_clip_kinds.py into Resources/clip-kinds.bin. Windows does the same with
/// the same model and file.
@interface POKindEncoder : NSObject

/// Nil with `error` when the model is not downloaded or can't be loaded.
+ (nullable instancetype)encoderWithError:(NSError **)error;

/// The image's vector, unit length, as float16 — what the analysis keeps; nil when it can't be computed.
- (nullable NSData *)vectorForImage:(CGImageRef)image;

@end

/// How likely the image with this vector (as POKindEncoder makes it) is a picture and a collage, 0…1 each (the rest is
/// a photo). NO when the vector or the descriptions can't be read.
FOUNDATION_EXPORT BOOL POKindScores(NSData *_Nullable vector, float *picture, float *collage);

/// What the analysis found, set on `item` (pictureScore, collageScore); clears them for a nil vector.
FOUNDATION_EXPORT void POSetKindVector(POPhotoItem *item, NSData *_Nullable vector);

NS_ASSUME_NONNULL_END
