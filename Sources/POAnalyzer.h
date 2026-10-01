#import <Foundation/Foundation.h>
#import "POPhotoItem.h"
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Fills in `labels` (what is in the picture, via the classifier built into macOS) and, when the optional
/// nudity model is enabled and ready, `nudityScore` for a list of files. Results are remembered between
/// launches, so every file is analysed once. Videos are judged by a few frames spread over their length.
@interface POAnalyzer : NSObject

- (instancetype)initWithItems:(NSArray<POPhotoItem *> *)items NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Both blocks are called on the main queue. `errorMessage` is set when the nudity model could not be started
/// (object recognition still runs in that case). `completion` is not called after -cancel.
- (void)startWithProgress:(nullable void (^)(NSUInteger done, NSUInteger total))progress
               completion:(void (^)(NSString *_Nullable errorMessage))completion;

- (void)cancel;

/// What the built-in classifier sees in one picture (label → confidence).
+ (NSDictionary<NSString *, NSNumber *> *)labelsForImage:(CGImageRef)image;

/// The key results are remembered under for a file: changes when the file does, survives moving it.
+ (nullable NSString *)cacheKeyForURL:(NSURL *)url;

/// Forgets every remembered result (used by the settings window).
+ (void)removeAllCachedResults;

@end

NS_ASSUME_NONNULL_END
