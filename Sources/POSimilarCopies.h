#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Finds copies of one picture that are not byte-identical: resized, recompressed or re-saved versions.
@interface POSimilarCopies : NSObject

/// A 64-bit fingerprint of how the picture looks (a difference hash): copies of one picture get the same
/// value give or take a couple of bits, whatever their size or compression. nil for pictures too plain to
/// tell apart this way (a blank wall, a black frame).
+ (nullable NSNumber *)visualHashOfImage:(CGImageRef)image;

/// Sets of copies among `items`, each ordered best quality first (most pixels, then the larger file). Also
/// sets `betterCopy` on every lesser copy, `tiny` on the thumbnails among them (copies at most half as large as the
/// best version, along the longest side), and clears both on everything else. Exact duplicates (already known
/// from the scan) are left out. Blocking; safe off the main thread.
///
/// Deliberately strict, because the result is offered for deletion: fingerprints at most 2 bits apart, the
/// same proportions, — when both files know when they were shot — the same second, and then the pictures
/// themselves compared pixel by pixel (which reads the candidate files). Two frames of a burst, or two screenshots
/// of one app with other numbers, therefore stay two pictures.
+ (NSArray<NSArray<POPhotoItem *> *> *)setsInItems:(NSArray<POPhotoItem *> *)items;

/// YES when the picture at `url` shows what `item` shows, pixel by pixel, though saved differently (other metadata,
/// compression or size) — the same test the sets above pass. Reads both files; NO for a video or an unreadable file.
+ (BOOL)isSamePictureAtURL:(NSURL *)url asItem:(POPhotoItem *)item;

/// Gives every copy in `sets` that has no date of its own the date of a copy in the same set that has one
/// (from metadata, the file name or Google Takeout). Returns how many files got a date.
+ (NSUInteger)shareDatesInSets:(NSArray<NSArray<POPhotoItem *> *> *)sets;
/// Which of a RAW photo and a JPEG (or HEIC) of the same shot is kept as the original: 0 the better quality (the RAW,
/// most pixels), 1 the RAW, 2 the JPEG — a library that already has the JPEGs can let the RAW files go. Remembered.
@property (class, nonatomic) NSInteger rawPreference;
/// Which copy is kept: 0 the better quality, 1 the compressed one — of a RAW and a JPEG of one shot the JPEG, of
/// copies of a video HEVC, then the lightest. Among ordinary photos the larger still wins. As on Windows.
@property (class, nonatomic) NSInteger compressedPreference;
/// `sets` put in order again after rawPreference changed, and marked anew on the files.
+ (NSArray<NSArray<POPhotoItem *> *> *)reorderedSets:(NSArray<NSArray<POPhotoItem *> *> *)sets;

@end

NS_ASSUME_NONNULL_END
