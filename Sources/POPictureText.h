#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Whether a picture is worth reading for text: reading every photo of a large library at full size would take
/// hours, and most photos have none. Screenshots (PNG, or a phone screen's proportions) and pictures recognised as
/// documents, signs, screens… are read.
FOUNDATION_EXPORT BOOL POWorthReadingText(POPhotoItem *item, NSDictionary<NSString *, NSNumber *> *_Nullable labels);

/// The text written in a picture, read by Vision in Russian and English where this macOS knows them: lines joined by
/// line breaks, lower-cased and with ё as е, as the search compares. Empty when there is none; nil when Vision
/// failed, so that the picture is tried again another time instead of being remembered as having no text.
FOUNDATION_EXPORT NSString *_Nullable POTextInImage(CGImageRef _Nullable image);

/// The longest side pictures are decoded at for reading text.
FOUNDATION_EXPORT const NSInteger POTextPixelSize;

NS_ASSUME_NONNULL_END
