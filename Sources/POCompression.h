#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// "Сжать…", the same as on Windows: RAW photos become JPEGs of the size most photos of the library have, with the
/// camera's HDR kept as a gain map (Ultra HDR / ISO 21496-1); videos become HEVC no larger than a chosen height, at a
/// bitrate that loses nothing visible, HDR (HLG / PQ, 10 bits) kept. Each compressed file takes the place of its
/// original, which goes to the Trash.

/// The heights a video may be brought down to: 4K, 1080p, 720p (its shorter side, for a vertical one).
FOUNDATION_EXPORT NSArray<NSNumber *> *POCompressionVideoHeights(void);
FOUNDATION_EXPORT const NSInteger POCompressionDefaultVideoHeight;
/// "Максимальное", "Высокое", "Экономное".
FOUNDATION_EXPORT const NSInteger POCompressionDefaultVideoQuality;

/// A camera RAW photo (DNG, CR2, NEF…).
FOUNDATION_EXPORT BOOL POIsRawItem(POPhotoItem *item);

/// The size most photos of the library have (in megapixels, 12 for an iPhone), how many bytes they take per megapixel
/// and how many there are — what a compressed RAW is made like and what its size is guessed from.
FOUNDATION_EXPORT void POTypicalPhoto(NSArray<POPhotoItem *> *items, NSInteger *megapixels, double *bytesPerMegapixel, NSInteger *count);

/// The size of a photo brought to `megapixels`, never larger; exactly half or a quarter when about that.
FOUNDATION_EXPORT CGSize POCompressedPhotoSize(NSInteger width, NSInteger height, NSInteger megapixels);

/// What a video is, upright (a vertical one is taller than wide).
@interface POVideoInfo : NSObject
@property (nonatomic) NSInteger width, height;
@property (nonatomic) double fps, duration;
@property (nonatomic) long long videoBitrate, audioBitrate;
/// HLG or PQ.
@property (nonatomic) BOOL hdr;
@property (nonatomic) BOOL tenBit;
@end

/// A video to compress: its new size (upright) and bitrate, and how large it should come out.
@interface POVideoJob : NSObject
@property (nonatomic) NSInteger width, height;
@property (nonatomic) long long bitrate, estimatedSize;
@end

/// Bits per second HEVC needs to lose nothing visible at that size and frame rate (`quality` 0…2).
FOUNDATION_EXPORT long long POVideoBitrate(NSInteger width, NSInteger height, double fps, NSInteger quality);
/// What compressing a video does; nil when it would gain too little.
FOUNDATION_EXPORT POVideoJob *_Nullable POPlanVideo(POVideoInfo *info, NSInteger maxHeight, NSInteger quality);
/// Reads a video's size, frame rate, bitrate and colours; nil when it cannot be read.
FOUNDATION_EXPORT POVideoInfo *_Nullable POProbeVideo(NSURL *url);

/// What happened to one file.
@interface POCompressionOutcome : NSObject
@property (nonatomic, strong) POPhotoItem *item;
/// Where the compressed file is; nil when the original stays (an error, or nothing to gain).
@property (nonatomic, strong, nullable) NSURL *compressedURL;
@property (nonatomic) long long before, after;
@property (nonatomic) BOOL hdr;
@property (nonatomic, copy, nullable) NSString *error;
@end

/// Compresses a RAW photo into JPEG data of `megapixels`; nil (and why) when it cannot be read.
FOUNDATION_EXPORT NSData *_Nullable POCompressRawPhoto(NSURL *url, NSInteger megapixels, BOOL *_Nullable hdr, NSString *_Nullable *_Nullable error);
/// A RAW photo replaced by a JPEG of the same name.
FOUNDATION_EXPORT POCompressionOutcome *POCompressPhotoItem(POPhotoItem *item, NSInteger megapixels);
/// A video replaced by its compressed version under the same name. `progress` gets 0…1; `cancelled` stops it.
FOUNDATION_EXPORT POCompressionOutcome *POCompressVideoItem(POPhotoItem *item, POVideoInfo *info, POVideoJob *job,
                                                            void (^_Nullable progress)(double fraction), BOOL (^cancelled)(void));

/// "1,2 ГБ → 300 МБ (−75 %)".
FOUNDATION_EXPORT NSString *POCompressionSaving(long long before, long long after);
/// "12,3 ГБ" (the system's way of writing sizes).
FOUNDATION_EXPORT NSString *POByteSize(long long bytes);

NS_ASSUME_NONNULL_END
