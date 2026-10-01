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

- (instancetype)initWithRootURL:(NSURL *)rootURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *rootURL;
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
