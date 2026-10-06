#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN


/// Finds a date (and time, when present) written in a file name: "20220909_145141.mp4", "IMG-20220909-WA0001.jpg",
/// "Screenshot 2022-09-09 at 14.51.41.png". Returns nil when there is none.
FOUNDATION_EXPORT NSDate *_Nullable PODateFromFileName(NSString *name);

typedef NS_ENUM(NSInteger, POScanPhase) {
    POScanPhaseEnumerating,   // total is unknown (0), done = images found so far
    POScanPhaseMetadata,
    POScanPhaseDuplicates,
};

typedef void (^POScanProgress)(POScanPhase phase, NSUInteger done, NSUInteger total);

/// Finds every image and video under a folder, reads its date and pixel size, and detects byte-identical copies.
@interface POScanner : NSObject

/// A library of several folders, scanned together (copies are found across them). A folder inside another one is
/// left out: the outer one covers it.
- (instancetype)initWithRootURLs:(NSArray<NSURL *> *)rootURLs NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithRootURL:(NSURL *)rootURL;
/// Canonical paths (/private/var/… rather than /var/…), without folders inside another one of them.
+ (NSArray<NSURL *> *)normalizedRootURLs:(NSArray<NSURL *> *)urls;
- (instancetype)init NS_UNAVAILABLE;

/// The first folder of the library.
@property (nonatomic, readonly) NSURL *rootURL;
@property (nonatomic, readonly, copy) NSArray<NSURL *> *rootURLs;
/// Top-level folder names whose files should never be picked as the original of a duplicate set.
@property (nonatomic, copy) NSArray<NSString *> *deprioritizedFolders;

/// Blocking scan. `progress` is called from arbitrary threads. Returns nil when cancelled.
- (nullable NSArray<POPhotoItem *> *)scanWithProgress:(nullable POScanProgress)progress;

/// Runs the scan on a background queue; both blocks are called on the main queue.
- (void)startWithProgress:(nullable POScanProgress)progress
               completion:(void (^)(NSArray<POPhotoItem *> *_Nullable items))completion;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
