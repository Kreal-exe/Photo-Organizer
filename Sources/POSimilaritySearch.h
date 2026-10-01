#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Search by example. Works in two steps: the example is first described in words (the classifier's labels,
/// which the user can switch off one by one), the words pick the candidate files, and then a visual model
/// built into macOS compares each candidate with the example and orders them by likeness.
@interface POSimilaritySearch : NSObject

/// A downsized, upright version of an image file; NULL when it can't be read. The caller releases it.
+ (nullable CGImageRef)newImageWithContentsOfURL:(NSURL *)url CF_RETURNS_RETAINED;

/// `labels` are the words to search by; with none, every photo is compared visually (slower).
/// Blocks are called on the main queue; the result is ordered most similar first.
+ (void)findItemsSimilarToImage:(CGImageRef)image
                         labels:(NSArray<NSString *> *)labels
                        inItems:(NSArray<POPhotoItem *> *)items
                       progress:(nullable void (^)(NSUInteger done, NSUInteger total))progress
                     completion:(void (^)(NSArray<POPhotoItem *> *results))completion;

@end

NS_ASSUME_NONNULL_END
