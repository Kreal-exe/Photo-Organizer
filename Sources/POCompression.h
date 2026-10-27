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
/// Why the video is not compressed at all (a 3D video, a second video track) — compressing would lose part of it.
@property (nonatomic, copy, nullable) NSString *kept;
/// HEVC already: compressed again only when well above the planned bitrate (see POPlanVideo).
@property (nonatomic) BOOL hevc;
/// Compressed by the earlier version of this app (HEVC that FFmpeg wrote, with B-frames): phones play it in jerks, so it
/// is built again (POVideoJob.rebuild). As on Windows.
@property (nonatomic) BOOL stutters;
/// "dolby vision", "vivid" or "hdr10+": HDR whose frames say how bright each scene is shown, which the encoder drops;
/// POCarryHdr puts it back into the compressed file. As on Windows.
@property (nonatomic, copy, nullable) NSString *dynamicHdr;
/// The frames are stored out of order (B-frames) but marked shown in the order stored: players show them in jerks. The
/// moments are made afresh from the order the frames are decoded in, which is the right one. As on Windows.
@property (nonatomic) BOOL flatTimestamps;
/// Written by FFmpeg (this app, or another tool): encoded again after the camera.
@property (nonatomic) BOOL reencoded;
@end

/// A video to compress: its new size (upright) and bitrate, and how large it should come out.
@interface POVideoJob : NSObject
@property (nonatomic) NSInteger width, height;
@property (nonatomic) long long bitrate, estimatedSize;
/// The video is compressed already (HEVC near the quality asked); it can be squeezed further, if asked.
@property (nonatomic) BOOL again;
/// The quality asked (0 maximum, 1 high, 2 compact): the encoder works to it rather than to `bitrate`, the plan's
/// average, so that a busy scene gets the bits it needs. As on Windows.
@property (nonatomic) NSInteger quality;
/// Built again as a camera builds it, at its own size and almost without loss; it replaces the old one even if larger.
@property (nonatomic) BOOL rebuild;
@end

/// Bits per second HEVC needs to lose nothing visible at that size and frame rate (`quality` 0…2).
FOUNDATION_EXPORT long long POVideoBitrate(NSInteger width, NSInteger height, double fps, NSInteger quality);
/// The kinds of video by resolution (their shorter side): 4K, 1440p, 1080p, 720p and less.
FOUNDATION_EXPORT NSArray<NSString *> *POVideoResolutionNames(void);
/// Which of POVideoResolutionNames a video is: 4K takes most when brought down, 1080p little.
FOUNDATION_EXPORT NSInteger POVideoResolutionClass(POVideoInfo *info);
/// The same for a size: by the shorter side, so that a vertical video is what its horizontal twin is.
FOUNDATION_EXPORT NSInteger POResolutionClassOfSize(NSInteger width, NSInteger height);
/// What compressing a video does; nil when it would gain too little.
FOUNDATION_EXPORT POVideoJob *_Nullable POPlanVideo(POVideoInfo *info, NSInteger maxHeight, NSInteger quality);
/// Reads a video's size, frame rate, bitrate and colours; nil when it cannot be read.
FOUNDATION_EXPORT POVideoInfo *_Nullable POProbeVideo(NSURL *url);
/// POProbeVideo, remembered: a video read once is not read again until its size or date changes, so the compress
/// window knows the library's videos at once the next time. POSaveProbedVideos writes what was learned. As on Windows.
FOUNDATION_EXPORT POVideoInfo *_Nullable POProbeVideoRemembered(NSURL *url);
FOUNDATION_EXPORT void POSaveProbedVideos(void);

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
