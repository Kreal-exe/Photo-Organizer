#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PODateSource) {
    PODateSourceEXIF,   // capture date embedded in the file (EXIF for images, container metadata for videos)
    PODateSourceFile,   // nothing better than the file system's date, which is usually when the file was copied:
                        // the file counts as undated
    PODateSourceName,   // date written in the file name (20220909_145141.mp4)
    PODateSourceNeighbors,   // no date of its own; taken from the shots before and after it in the same numbered series
    PODateSourceTakeout,     // from the .json file Google Takeout puts next to every photo (photoTakenTime)
    PODateSourceCopy,        // no date of its own; taken from another copy of the same picture that has one
    PODateSourceNeighborsMonth, // no date of its own; the numbered shots before and after it are from the same month
    PODateSourceManual,      // set by the user in the app (see POManualDates.h)
};

/// How much of the date is actually known.
typedef NS_ENUM(NSInteger, PODatePrecision) {
    PODatePrecisionDay,
    PODatePrecisionMonth,
    PODatePrecisionYear,
};

/// The date as it should be shown: "12 мар. 2019 г.", or just "2018" / "май 2018 г." when only that much is known.
@class POPhotoItem;
FOUNDATION_EXPORT PODatePrecision POItemDatePrecision(POPhotoItem *item);
/// Where the date came from, for the tooltip ("Дата съёмки (из метаданных)").
FOUNDATION_EXPORT NSString *POItemDateSourceText(POPhotoItem *item);
FOUNDATION_EXPORT NSString *POItemDateText(POPhotoItem *item, BOOL withTime);

/// One image or video file found by the scanner.
@interface POPhotoItem : NSObject

- (instancetype)initWithURL:(NSURL *)url relativePath:(NSString *)relativePath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *url;
/// Path relative to the scanned root, e.g. "Trip/IMG_0001.jpg".
@property (nonatomic, readonly, copy) NSString *relativePath;
/// Folder the file currently lives in, relative to the root ("" for the root itself).
@property (nonatomic, readonly, copy) NSString *currentFolder;

/// The file was moved (by the app): follow it, keeping everything known about it.
- (void)movedToURL:(NSURL *)url relativePath:(NSString *)relativePath;

@property (nonatomic) unsigned long long fileSize;
@property (nonatomic, strong) NSDate *date;
@property (nonatomic) PODateSource dateSource;
/// Where it was taken (degrees), from the photo's GPS data or the video's location; hasLocation says whether known.
@property (nonatomic) BOOL hasLocation;
@property (nonatomic) double latitude;
@property (nonatomic) double longitude;
/// For PODateSourceManual: how much of the date the user gave.
@property (nonatomic) PODatePrecision manualPrecision;
/// The file system's date (the earlier of creation and modification), kept for suggestions.
@property (nonatomic, strong, nullable) NSDate *fileDate;
/// No date was found anywhere in or around the file, and the user has not given one.
@property (nonatomic, readonly, getter=isUndated) BOOL undated;
/// 0 when the image could not be read.
@property (nonatomic) NSInteger pixelWidth;
@property (nonatomic) NSInteger pixelHeight;
/// A thumbnail: a small copy of another, larger photo of the folder (set once copies have been compared,
/// see POSimilarCopies.h). A small picture that exists only in small size is not a thumbnail.
@property (atomic, getter=isTiny) BOOL tiny;
@property (nonatomic, getter=isVideo) BOOL video;
/// Seconds; 0 for images.
@property (nonatomic) NSTimeInterval duration;
/// The file is an iCloud placeholder whose contents are not on this Mac. Reading it would download it, so the
/// scanner only looks at its file date and never hashes it.
@property (nonatomic, getter=isCloudOnly) BOOL cloudOnly;

/// What Vision recognised in the picture (label identifier → confidence); nil until analysed.
@property (atomic, copy, nullable) NSDictionary<NSString *, NSNumber *> *labels;
/// One embedding per face found in the photo (see POFaces.h); nil when not analysed, empty when there are none.
@property (atomic, copy, nullable) NSArray<NSData *> *faces;
/// How many people the photo shows: every face Vision finds, however small or turned away, or every human
/// figure when there are more of those. Nil when not counted.
@property (atomic, strong, nullable) NSNumber *peopleCount;
/// Fingerprint of how the picture looks (see POSimilarCopies.h); nil when not analysed or too plain to compare.
@property (atomic, strong, nullable) NSNumber *visualHash;
/// Set on a resized or recompressed copy: the better-quality version of the same picture.
@property (atomic, weak, nullable) POPhotoItem *betterCopy;
/// Set on the best version of a picture that also exists as lesser copies.
@property (atomic) BOOL bestOfCopies;
/// 0…1 from the optional nudity model; nil when not analysed.
@property (atomic, strong, nullable) NSNumber *nudityScore;

@property (nonatomic, copy, nullable) NSString *contentHash;
/// Set on every copy; points to the file that is kept as the original.
@property (nonatomic, weak, nullable) POPhotoItem *duplicateOf;
/// Set on the original; byte-identical copies of it.
@property (nonatomic, copy, nullable) NSArray<POPhotoItem *> *duplicates;
@property (nonatomic, readonly, getter=isDuplicate) BOOL duplicate;

/// Folder assigned by the plan, relative to the root.
@property (nonatomic, copy, nullable) NSString *destinationFolder;
@property (nonatomic, readonly) BOOL needsMove;

@end

NS_ASSUME_NONNULL_END
