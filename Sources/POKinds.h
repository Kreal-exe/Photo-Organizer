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

/// The image's vectors, unit length, as float16 — what the analysis keeps: one of its centre (as MobileCLIP was
/// trained) and one of the whole image fitted into the square (a photo of a priest holding an icon is an icon in its
/// centre). Nil when they can't be computed.
- (nullable NSArray<NSData *> *)vectorsForImage:(CGImageRef)image;

@end

/// How likely an image with these vectors (as POKindEncoder makes them) is a picture and a collage, 0…1 each (the rest
/// is a photo): the mean of what each view says. NO when the vectors or the descriptions can't be read.
FOUNDATION_EXPORT BOOL POKindScores(NSArray<NSData *> *_Nullable vectors, float *picture, float *collage);

/// What the analysis found, set on `item` (pictureScore, collageScore); clears them for nil vectors.
FOUNDATION_EXPORT void POSetKindVectors(POPhotoItem *item, NSArray<NSData *> *_Nullable vectors);

NS_ASSUME_NONNULL_END
